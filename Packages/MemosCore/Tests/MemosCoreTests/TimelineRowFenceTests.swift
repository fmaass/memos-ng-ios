import Foundation
import HTTPTypes
import MemosAPI
import MemosOutbox
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let listMemosOperation = "list_memos_api_memos_get"
private let getMemoOperation = "get_memo_api_memos__uid__get"
private let patchMemoOperation = "patch_memo_api_memos__uid__patch"
private let startUploadOperation = "start_upload_api_uploads_post"
private let appendChunkOperation = "append_chunk_api_uploads__upload_uid__patch"
private let finalizeUploadOperation = "finalize_upload_api_uploads__upload_uid__finalize_post"

/// Keeps a request open until the test lets it go. `nonisolated`, because it is called from inside
/// the scripted transport, which the client runs off the main actor.
private func hold(until release: LockedValue<Bool>) async throws {
    while !release.get() {
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// One upload session's answer, in the shape the server sends it.
private func uploadOut(uid: String, chunkSize: Int, received: Int) -> String {
    """
    {"upload_uid":"\(uid)","chunk_size":\(chunkSize),"bytes_received":\(received)}
    """
}

/// A file on disk with known contents, cleaned up by the test that made it.
private func stagedFile(bytes: Int = 12, named name: String = "picked.jpg") throws -> StagedSource {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString)-\(name)")
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return StagedSource(url: url, filename: name, mime: "image/jpeg")
}

/// A memo body carrying tags, which `Stub.memo` hard-codes empty.
///
/// The tags are the server's projection of the words, so a save that rewrites the words rewrites
/// them too — and a read taken before that save still carries the old ones.
private func taggedMemo(
    uid: String,
    content: String,
    tags: [String],
    attachments: [String] = []
) -> String {
    let quoted = tags.map { "\"\($0)\"" }.joined(separator: ",")
    return """
        {"uid":"\(uid)","owner":"fabian","mine":true,"content":"\(Stub.jsonEscaped(content))",\
        "visibility":"PRIVATE","pinned":false,"created_at":"2026-08-23T09:00:00Z",\
        "updated_at":"2026-08-23T09:00:00.443000Z","archived_at":null,"tags":[\(quoted)],\
        "attachments":[\(attachments.joined(separator: ","))]}
        """
}

/// A row a mutation owns is not rewritten by a read that was issued before the mutation answered.
///
/// Every read of this timeline — the pull to refresh, the next page, the reconciling read behind a
/// media event — leaves the server the moment it is issued and lands whenever the network gets round
/// to it. A save issued after it can be confirmed by the server FIRST, so the answer that arrives
/// last is not the answer that knows most: it is simply the slower of two true statements about two
/// different instants. Judging the read against the moment it was issued is what keeps the older one
/// from undoing the newer, and it is the only thing that can — the row it carries is well formed,
/// the session is current, and nothing in the payload says it is stale.
///
/// A save still on its way is the same case seen early: the server has not answered yet, so the read
/// cannot be carrying its result, and the row it carries is one the user has already moved past.
@MainActor
@Suite("Fencing a row its own mutation owns")
struct TimelineRowFenceTests {
    @Test("a read that left before a save does not put the old words back")
    func aHeldReadDoesNotUndoTheSaveThatOutranIt() async throws {
        let store = TimelineStore()
        let gets = Counter()
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let payingEntered = LockedValue<Bool>(false)
        let payingRelease = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case getMemoOperation:
                let index = gets.count
                gets.increment()
                if index == 0 {
                    entered.set(true)
                    try await hold(until: release)
                    return Stub.json(
                        Stub.memo(
                            uid: "a", content: "old",
                            attachments: [Stub.attachment(uid: "p", status: "ready")]
                        )
                    )
                }
                // The read that pays for the held one leaves after the server confirmed the save,
                // so the server it asks answers with the words it confirmed. It is held where the
                // first one was, because it carries everything the refused read carried: what the
                // row is asserted to hold has to be asserted before this answer can supply it.
                payingEntered.set(true)
                try await hold(until: payingRelease)
                return Stub.json(
                    Stub.memo(
                        uid: "a", content: "new",
                        attachments: [Stub.attachment(uid: "p", status: "ready")]
                    )
                )
            case patchMemoOperation:
                return Stub.json(
                    Stub.memo(
                        uid: "a", content: "new",
                        attachments: [Stub.attachment(uid: "p", status: "pending")]
                    )
                )
            default:
                return Stub.json(
                    Stub.page([
                        Stub.memo(
                            uid: "a", content: "old",
                            attachments: [Stub.attachment(uid: "p", status: "pending")]
                        )
                    ])
                )
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let reading = Task {
            await store.refreshMemo(uid: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        await store.edit(uid: "a", content: "new", using: client.handle, baseURL: Stub.baseURL)
        release.set(true)
        _ = await reading.value
        // Bounded, and the bound is not a detector: the row assertions below are about the window
        // BEFORE the payment lands, so a store that never pays must let them run and let the suite
        // end rather than spin for an answer that is never coming. Payment has its own witness.
        let payingDue = Date().addingTimeInterval(2)
        while !payingEntered.get() && Date() < payingDue {
            await Task.yield()
        }

        // The row as the refused read left it: the payment is out and cannot have touched it.
        #expect(store.memos.first?.content == "new")
        #expect(store.memos.first?.attachments.map(\.uid) == ["p"])
        // What the read is FOR still lands: the tiers it reports are the freshest fact about that
        // file, and the save says nothing about them.
        #expect(store.memos.first?.attachments.first?.status == .ready)

        payingRelease.set(true)
        await store.owedReadsSettled()

        #expect(store.memos.first?.content == "new")
        #expect(store.memos.first?.attachments.first?.status == .ready)
    }

    @Test("a read that left before a save does not put the old tags back")
    func aHeldReadDoesNotRestoreTheTagsTheSaveReplaced() async throws {
        let store = TimelineStore()
        let gets = Counter()
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let payingEntered = LockedValue<Bool>(false)
        let payingRelease = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case getMemoOperation:
                let index = gets.count
                gets.increment()
                if index == 0 {
                    entered.set(true)
                    try await hold(until: release)
                    return Stub.json(
                        taggedMemo(
                            uid: "a", content: "#old", tags: ["old"],
                            attachments: [Stub.attachment(uid: "p", status: "ready")]
                        )
                    )
                }
                // The read that pays for the held one leaves after the server confirmed the save,
                // so the tags it carries are the ones the save's own words project to. It is held
                // where the first one was: it would put right anything the refused read got wrong,
                // so the row is asserted while it is still out.
                payingEntered.set(true)
                try await hold(until: payingRelease)
                return Stub.json(
                    taggedMemo(
                        uid: "a", content: "#new", tags: ["new"],
                        attachments: [
                            Stub.attachment(uid: "p", status: "ready"),
                            Stub.attachment(uid: "q", status: "pending"),
                        ]
                    )
                )
            case patchMemoOperation:
                return Stub.json(
                    taggedMemo(
                        uid: "a", content: "#new", tags: ["new"],
                        attachments: [
                            Stub.attachment(uid: "p", status: "ready"),
                            Stub.attachment(uid: "q", status: "pending"),
                        ]
                    )
                )
            default:
                return Stub.json(
                    Stub.page([
                        taggedMemo(
                            uid: "a", content: "#old", tags: ["old"],
                            attachments: [Stub.attachment(uid: "p", status: "ready")]
                        )
                    ])
                )
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let reading = Task {
            await store.refreshMemo(uid: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        await store.edit(uid: "a", content: "#new", using: client.handle, baseURL: Stub.baseURL)
        release.set(true)
        _ = await reading.value
        // Bounded, and the bound is not a detector: the row assertions below are about the window
        // BEFORE the payment lands, so a store that never pays must let them run and let the suite
        // end rather than spin for an answer that is never coming. Payment has its own witness.
        let payingDue = Date().addingTimeInterval(2)
        while !payingEntered.get() && Date() < payingDue {
            await Task.yield()
        }

        // The whole row as the refused read left it, payment still out: the words, the tags the
        // save's words project to, both files — and the one tier the refused read did get to say.
        #expect(store.memos.first?.content == "#new")
        #expect(store.memos.first?.tags == ["new"])
        #expect(store.memos.first?.attachments.map(\.uid) == ["p", "q"])
        #expect(store.memos.first?.attachments.map(\.status) == [.ready, .pending])

        payingRelease.set(true)
        await store.owedReadsSettled()

        #expect(store.memos.first?.tags == ["new"])
        #expect(store.memos.first?.attachments.map(\.uid) == ["p", "q"])
    }

    @Test("a save that never left the device does not hold off the list behind it")
    func aSaveThatNeverLeftDoesNotHoldOffTheListBehindIt() async throws {
        let file = try stagedFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let lists = Counter()
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.empty(.internalServerError)
            case listMemosOperation:
                let index = lists.count
                lists.increment()
                if index == 0 {
                    return Stub.json(Stub.page([Stub.memo(uid: "a", content: "A")]))
                }
                entered.set(true)
                try await hold(until: release)
                return Stub.json(Stub.page([Stub.memo(uid: "a", content: "B")]))
            default:
                return Stub.empty(.notFound)
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let refreshing = Task {
            await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        await store.edit(
            uid: "a", content: "C", attaching: [file],
            using: client.handle, baseURL: Stub.baseURL
        )
        release.set(true)
        await refreshing.value

        #expect(store.memos.first?.content == "B")
    }

    @Test("two saves that both failed leave the list they were holding free")
    func twoFailedSavesLeaveTheListFree() async throws {
        let first = try stagedFile()
        let second = try stagedFile(named: "second.jpg")
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }

        let store = TimelineStore()
        let lists = Counter()
        let uploads = Counter()
        let listEntered = LockedValue<Bool>(false)
        let uploadEntered = LockedValue<Bool>(false)
        let listRelease = LockedValue<Bool>(false)
        let uploadRelease = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                let index = uploads.count
                uploads.increment()
                if index == 0 {
                    uploadEntered.set(true)
                    try await hold(until: uploadRelease)
                }
                return Stub.empty(.internalServerError)
            case listMemosOperation:
                let index = lists.count
                lists.increment()
                if index == 0 {
                    return Stub.json(Stub.page([Stub.memo(uid: "a", content: "A")]))
                }
                listEntered.set(true)
                try await hold(until: listRelease)
                return Stub.json(Stub.page([Stub.memo(uid: "a", content: "B")]))
            default:
                return Stub.empty(.notFound)
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let refreshing = Task {
            await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        }
        while !listEntered.get() {
            await Task.yield()
        }
        let sending = Task {
            await store.edit(
                uid: "a", content: "X", attaching: [first],
                using: client.handle, baseURL: Stub.baseURL
            )
        }
        while !uploadEntered.get() {
            await Task.yield()
        }
        // One turn of the main actor: the place in line is taken by synchronous code, so this is
        // all the second save needs to be queued behind the first.
        let queued = Task {
            await store.edit(
                uid: "a", content: "Y", attaching: [second],
                using: client.handle, baseURL: Stub.baseURL
            )
        }
        await Task.yield()
        uploadRelease.set(true)
        _ = await sending.value
        _ = await queued.value
        listRelease.set(true)
        await refreshing.value

        #expect(store.memos.first?.content == "B")
    }

    @Test("a save still on its way keeps the list from overwriting the row it owns")
    func aSaveStillOnItsWayKeepsTheListFromOverwritingItsRow() async throws {
        let first = try stagedFile()
        let second = try stagedFile(named: "second.jpg")
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }

        let store = TimelineStore()
        let lists = Counter()
        let uploads = Counter()
        let listEntered = LockedValue<Bool>(false)
        let uploadEntered = LockedValue<Bool>(false)
        let listRelease = LockedValue<Bool>(false)
        let uploadRelease = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                let index = uploads.count
                uploads.increment()
                if index == 0 {
                    return Stub.empty(.internalServerError)
                }
                uploadEntered.set(true)
                try await hold(until: uploadRelease)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            case appendChunkOperation:
                let data = try await Stub.bytes(body)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: data.count))
            case finalizeUploadOperation:
                return Stub.empty(.ok)
            case patchMemoOperation:
                let content = (try await Stub.body(body))["content"] as? String ?? ""
                return Stub.json(Stub.memo(uid: "a", content: content))
            // The read that pays for the held list leaves once no save owns the row any more, so
            // the server it asks answers with the words the last of them confirmed.
            case getMemoOperation:
                return Stub.json(Stub.memo(uid: "a", content: "Y"))
            case listMemosOperation:
                let index = lists.count
                lists.increment()
                if index == 0 {
                    return Stub.json(Stub.page([Stub.memo(uid: "a", content: "A")]))
                }
                listEntered.set(true)
                try await hold(until: listRelease)
                return Stub.json(Stub.page([Stub.memo(uid: "a", content: "B")]))
            default:
                return Stub.empty(.notFound)
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let refreshing = Task {
            await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        }
        while !listEntered.get() {
            await Task.yield()
        }
        let failing = Task {
            await store.edit(
                uid: "a", content: "X", attaching: [first],
                using: client.handle, baseURL: Stub.baseURL
            )
        }
        await Task.yield()
        let queued = Task {
            await store.edit(
                uid: "a", content: "Y", attaching: [second],
                using: client.handle, baseURL: Stub.baseURL
            )
        }
        while !uploadEntered.get() {
            await Task.yield()
        }
        _ = await failing.value
        listRelease.set(true)
        await refreshing.value

        #expect(store.memos.first?.content == "A")

        uploadRelease.set(true)
        _ = await queued.value
        await store.owedReadsSettled()

        #expect(store.memos.first?.content == "Y")
    }

    @Test("a save the server refused does not hold off the list behind it")
    func aRefusedSaveDoesNotHoldOffTheListBehindIt() async throws {
        let store = TimelineStore()
        let lists = Counter()
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case patchMemoOperation:
                // The refusal as the contract writes it, body and all. An empty 409 is an answer
                // this client cannot READ, which says nothing about what became of the memo — a
                // different case from the one this test is about.
                return Stub.json(
                    #"{"detail":{"code":"edit_key_conflict","memo_uid":"b","message":"bound"}}"#,
                    status: .conflict
                )
            case listMemosOperation:
                let index = lists.count
                lists.increment()
                if index == 0 {
                    return Stub.json(Stub.page([Stub.memo(uid: "a", content: "A")]))
                }
                entered.set(true)
                try await hold(until: release)
                return Stub.json(Stub.page([Stub.memo(uid: "a", content: "B")]))
            default:
                return Stub.empty(.notFound)
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let refreshing = Task {
            await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        await store.edit(uid: "a", content: "C", using: client.handle, baseURL: Stub.baseURL)
        release.set(true)
        await refreshing.value

        #expect(store.memos.first?.content == "B")
    }

    @Test("a page carrying a memo a save owns leaves that memo out")
    func aPageCarryingASavedMemoLeavesItOut() async throws {
        let store = TimelineStore()
        let lists = Counter()
        let patchEntered = LockedValue<Bool>(false)
        let pageEntered = LockedValue<Bool>(false)
        let patchRelease = LockedValue<Bool>(false)
        let pageRelease = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case patchMemoOperation:
                patchEntered.set(true)
                try await hold(until: patchRelease)
                return Stub.json(Stub.memo(uid: "z", content: "kept"))
            case listMemosOperation:
                let index = lists.count
                lists.increment()
                if index == 0 {
                    return Stub.json(
                        Stub.page([Stub.memo(uid: "a", content: "A")], nextCursor: "c1")
                    )
                }
                pageEntered.set(true)
                try await hold(until: pageRelease)
                return Stub.json(
                    Stub.page([
                        Stub.memo(uid: "z", content: "stale"),
                        Stub.memo(uid: "b", content: "B"),
                    ])
                )
            default:
                return Stub.empty(.notFound)
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let editing = Task {
            await store.edit(uid: "z", content: "kept", using: client.handle, baseURL: Stub.baseURL)
        }
        while !patchEntered.get() {
            await Task.yield()
        }
        let paging = Task {
            await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        }
        while !pageEntered.get() {
            await Task.yield()
        }
        patchRelease.set(true)
        _ = await editing.value
        pageRelease.set(true)
        await paging.value

        // The memo the save owns is not on this screen, so there is no row to keep and nothing the
        // page could say about it that is not already out of date: it is left out until a read
        // issued after the save brings it back.
        #expect(store.memos.map(\.uid) == ["a", "b"])
    }

    /// A read the row's own save fenced is paid back, once the row is free again, by exactly one
    /// fresh read — without it, what that read carried and the row lacks stays missing for good.
    ///
    /// The loaded row holds a file still waiting for its tiers, and another client has added a
    /// second one. The read that would have brought both in lands while a save owns the row, so its
    /// membership is refused and only the tiers of the file the row already holds are taken. From
    /// there nothing asks for that memo again on its own: the row no longer waits for tiers, and an
    /// event about a file the row does not hold changes nothing. The debt that read left is the
    /// only thing that brings the second file in.
    @Test("a read a save fenced is paid back by exactly one fresh read")
    func aFencedReadIsPaidBackByOneFreshRead() async throws {
        let file = try stagedFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let gets = Counter()
        let readEntered = LockedValue<Bool>(false)
        let readRelease = LockedValue<Bool>(false)
        let uploadEntered = LockedValue<Bool>(false)
        let uploadRelease = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case getMemoOperation:
                let index = gets.count
                gets.increment()
                if index == 0 {
                    readEntered.set(true)
                    try await hold(until: readRelease)
                }
                return Stub.json(
                    Stub.memo(
                        uid: "a", content: "old",
                        attachments: [
                            Stub.attachment(uid: "p", status: "ready"),
                            Stub.attachment(uid: "q", status: "ready"),
                        ]
                    )
                )
            case startUploadOperation:
                uploadEntered.set(true)
                try await hold(until: uploadRelease)
                return Stub.empty(.internalServerError)
            case listMemosOperation:
                return Stub.json(
                    Stub.page([
                        Stub.memo(
                            uid: "a", content: "old",
                            attachments: [Stub.attachment(uid: "p", status: "pending")]
                        )
                    ])
                )
            default:
                return Stub.empty(.notFound)
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let reading = Task {
            await store.refreshMemo(uid: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        while !readEntered.get() {
            await Task.yield()
        }
        let saving = Task {
            await store.edit(
                uid: "a", content: "new", attaching: [file],
                using: client.handle, baseURL: Stub.baseURL
            )
        }
        while !uploadEntered.get() {
            await Task.yield()
        }
        readRelease.set(true)
        _ = await reading.value
        // The save never reaches the server, so the last claim leaves the row without applying
        // anything to it — the words the read carried are still the server's own.
        uploadRelease.set(true)
        _ = await saving.value

        await store.owedReadsSettled()

        #expect(gets.count == 2)
        #expect(store.memos.first?.attachments.map(\.uid) == ["p", "q"])

        // A debt is paid ONCE. The same save again leaves its claim the same way and finds nothing
        // owed: no read was refused since, so a third GET would be the first debt paid twice.
        await store.edit(
            uid: "a", content: "new", attaching: [file],
            using: client.handle, baseURL: Stub.baseURL
        )
        await store.owedReadsSettled()

        #expect(gets.count == 2)
    }

    /// The row is stamped when the server's answer is APPLIED, not when the save's task ends, and
    /// the instant between the two is what tells those apart: `commit` has already put the row in
    /// the list and is still writing the picture of it down, and a read issued after the save took
    /// its place in line lands there with the save unfinished.
    ///
    /// A place in line holds no read off on its own: a mutation that ends up changing nothing
    /// must not cost a reader the answer it went to fetch, so a read issued while a claim stands is
    /// judged against the claim's own instant and passes it. The stamp the confirmation takes is
    /// the only thing that can refuse this read, which is why the instant it is taken at is the
    /// whole of what this case is about.
    @Test("a read that lands while the row is being written down does not put the old words back")
    func aReadLandingWhileTheRowPersistsDoesNotRestoreTheOldText() async throws {
        let gets = Counter()
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let saveEntered = LockedValue<Bool>(false)
        let saveRelease = LockedValue<Bool>(false)
        let persisting = LockedValue<Bool>(false)
        let persistRelease = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case getMemoOperation:
                let index = gets.count
                gets.increment()
                if index == 0 {
                    entered.set(true)
                    try await hold(until: release)
                    return Stub.json(
                        Stub.memo(
                            uid: "a", content: "old",
                            attachments: [Stub.attachment(uid: "p", status: "ready")]
                        )
                    )
                }
                // The read that pays for the held one leaves after the server confirmed the save,
                // so the server it asks answers with the words it confirmed.
                return Stub.json(
                    Stub.memo(
                        uid: "a", content: "new",
                        attachments: [Stub.attachment(uid: "p", status: "ready")]
                    )
                )
            case patchMemoOperation:
                // Held so that the read under test can be issued while this save's place in line
                // is taken and nothing it asked for has been confirmed.
                saveEntered.set(true)
                try await hold(until: saveRelease)
                return Stub.json(
                    Stub.memo(
                        uid: "a", content: "new",
                        attachments: [Stub.attachment(uid: "p", status: "pending")]
                    )
                )
            default:
                return Stub.json(
                    Stub.page([
                        Stub.memo(
                            uid: "a", content: "old",
                            attachments: [Stub.attachment(uid: "p", status: "pending")]
                        )
                    ])
                )
            }
        }
        // The bytes-to-disk step is the one seam inside `commit` a test can stand in, and it is
        // reached with the row already in the list. Only the picture carrying the saved words is
        // held, so the read under test can still be awaited, and the wait is bounded: a store that
        // lets that read through has to fail this case rather than hang it.
        let snapshots = TimelineSnapshotWriter(
            store: TimelineSnapshotStore(
                root: FileManager.default.temporaryDirectory,
                writeData: { data, _ in
                    guard String(decoding: data, as: UTF8.self).contains("new") else { return }
                    persisting.set(true)
                    let deadline = Date().addingTimeInterval(2)
                    while !persistRelease.get() && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
            ),
            epoch: SessionEpoch()
        )
        let store = TimelineStore(
            snapshots: snapshots,
            snapshotIdentity: TimelineSnapshotIdentity(server: Stub.baseURL, subject: "fabian"),
            persists: true
        )

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saving = Task {
            await store.edit(uid: "a", content: "new", using: client.handle, baseURL: Stub.baseURL)
        }
        while !saveEntered.get() {
            await Task.yield()
        }
        let reading = Task {
            await store.refreshMemo(uid: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        saveRelease.set(true)
        while !persisting.get() {
            await Task.yield()
        }
        release.set(true)
        // The row this read is allowed to write reaches the list before the picture of it queues
        // behind the held one, and the tier it carries lands whether the rest of it was refused or
        // not — so it says the read has arrived without saying what it was allowed to say.
        // Bounded so an answer that never reaches the row ends the suite instead of spinning it.
        // The bound alone says nothing, so the tier the loop waited for is asserted the moment it
        // stops: that is what makes "it never arrived" a failure rather than a silent pass.
        let landingDue = Date().addingTimeInterval(2)
        while store.memos.first?.attachments.first?.status != .ready && Date() < landingDue {
            await Task.yield()
        }
        #expect(
            store.memos.first?.attachments.first?.status == .ready,
            "the tier the read was allowed to write never reached the row"
        )

        #expect(store.memos.first?.content == "new")

        persistRelease.set(true)
        _ = await reading.value
        _ = await saving.value
        await store.owedReadsSettled()

        #expect(store.memos.first?.content == "new")
        #expect(store.memos.first?.attachments.first?.status == .ready)
    }

    /// The boundary across an identity change: it waits for every payment that was out when it was
    /// called, although the change has forgotten them all, and a boundary called after the change
    /// waits for none of them.
    ///
    /// The change forgets the store's table of payments without cancelling a single one, so each
    /// paying read still lands — under the handle its debt was recorded with, and refused there.
    /// A test that changes the identity mid-payment asserts what those answers did NOT do to the
    /// incoming identity's list, which it can only assert once they have arrived. Two payments,
    /// because the table is re-read between awaits: a boundary that went back to it after the
    /// payment it was awaiting landed would find it emptied and leave the other one in flight.
    ///
    /// Which payment such a boundary awaits first is the table's iteration order, which is seeded
    /// per allocation and so differs from one store to the next: releasing in one order exposes it
    /// only when it awaited the payment released first. So each order is run over several fresh
    /// stores, and a boundary that lets go early survives a run with odds of 2^-(2 × rounds).
    @Test(
        "the boundary waits for every payment out at its call, though the identity has changed",
        arguments: ["a", "b"]
    )
    func theBoundaryWaitsOutPaymentsTheIdentityChangeForgot(releasingFirst first: String)
        async throws
    {
        for round in 1...5 {
            try await boundaryAcrossAnIdentityChange(releasingFirst: first, round: round)
        }
    }

    private func boundaryAcrossAnIdentityChange(releasingFirst first: String, round: Int)
        async throws
    {
        let second = first == "a" ? "b" : "a"
        let context = "releasing \(first) first, round \(round)"
        // Every wait below for something that MUST happen ends the moment it does, so this bound
        // costs a passing run nothing; it only decides how long a regression takes to fail. Two
        // seconds was within reach of a loaded simulator (MEMNG-693). The 200 ms windows further
        // down are a different thing — windows for something that must NOT happen — and keep
        // their length.
        let patience: Duration = .seconds(30)
        let store = TimelineStore()
        // One of each per memo: the two memos' requests run at once, and a shared table written
        // from both would lose one of the writes.
        func perMemo<Value>(_ make: () -> Value) -> [String: Value] { ["a": make(), "b": make()] }
        let reads = perMemo { Counter() }
        let readEntered = perMemo { LockedValue<Bool>(false) }
        let readRelease = LockedValue<Bool>(false)
        let payingEntered = perMemo { LockedValue<Bool>(false) }
        let payingAnswered = perMemo { LockedValue<Bool>(false) }
        let payingRelease = perMemo { LockedValue<Bool>(false) }
        // Whatever this round stops on, nothing it held stays held: a failed expectation must end
        // the suite, not leave a paying read spinning behind it.
        defer {
            readRelease.set(true)
            for release in payingRelease.values { release.set(true) }
        }
        let client = Stub.client { request, _, operation in
            let uid = request.path?.contains("/memos/b") == true ? "b" : "a"
            switch operation {
            case getMemoOperation:
                let index = reads[uid]?.count ?? 0
                reads[uid]?.increment()
                if index == 0 {
                    readEntered[uid]?.set(true)
                    try await hold(until: readRelease)
                    return Stub.json(Stub.memo(uid: uid, content: "old"))
                }
                payingEntered[uid]?.set(true)
                if let release = payingRelease[uid] {
                    try await hold(until: release)
                }
                payingAnswered[uid]?.set(true)
                return Stub.json(Stub.memo(uid: uid, content: "new"))
            case patchMemoOperation:
                return Stub.json(Stub.memo(uid: uid, content: "new"))
            default:
                return Stub.json(
                    Stub.page([
                        Stub.memo(uid: "a", content: "old"),
                        Stub.memo(uid: "b", content: "old"),
                    ])
                )
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["a", "b"], "control: the list loaded (\(context))")
        let readDone = perMemo { LockedValue<Bool>(false) }
        for uid in ["a", "b"] {
            Task {
                await store.refreshMemo(uid: uid, using: client.handle, baseURL: Stub.baseURL)
                readDone[uid]?.set(true)
            }
        }
        let readsDue = ContinuousClock.now + patience
        while !readEntered.values.allSatisfy({ $0.get() }) && ContinuousClock.now < readsDue {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(
            readEntered.values.allSatisfy { $0.get() },
            "both reads left before the saves (\(context))"
        )
        // Each save outruns the read held for its row, so each read is fenced on arrival and leaves
        // a debt that a fresh read pays.
        await store.edit(uid: "a", content: "new", using: client.handle, baseURL: Stub.baseURL)
        await store.edit(uid: "b", content: "new", using: client.handle, baseURL: Stub.baseURL)
        readRelease.set(true)
        let readsLandDue = ContinuousClock.now + patience
        while !readDone.values.allSatisfy({ $0.get() }) && ContinuousClock.now < readsLandDue {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(readDone.values.allSatisfy { $0.get() }, "both reads landed (\(context))")
        let payingDue = ContinuousClock.now + patience
        while !payingEntered.values.allSatisfy({ $0.get() }) && ContinuousClock.now < payingDue {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(
            payingEntered.values.allSatisfy { $0.get() },
            "both debts are being paid, both held (\(context))"
        )

        let settled = LockedValue<Bool>(false)
        // Started immediately, so the boundary has read the table and is waiting before the change
        // below can forget it: the call this test is about is one made while the payments are out.
        let boundary = Task.immediate {
            await store.owedReadsSettled()
            settled.set(true)
        }
        store.sessionIdentityChanged(
            to: TimelineSnapshotIdentity(server: Stub.baseURL, subject: "somebody-else")
        )
        #expect(store.memos.isEmpty, "control: the change emptied the list (\(context))")

        // A boundary called AFTER the change, with both forgotten payments still held: the table
        // it reads was emptied by the change, so it owes nothing and returns.
        let lateSettled = LockedValue<Bool>(false)
        let late = Task.immediate {
            await store.owedReadsSettled()
            lateSettled.set(true)
        }
        let lateDue = ContinuousClock.now + patience
        while !lateSettled.get() && ContinuousClock.now < lateDue {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(
            lateSettled.get(),
            "a boundary called after the change waited for a payment it forgot (\(context))"
        )
        #expect(
            !payingAnswered.values.contains { $0.get() },
            "control: both forgotten payments were still held when it returned (\(context))"
        )

        // A window, not a detector of its own: a boundary that let go when the table was emptied
        // returns inside it, and the expectation after it reads that.
        let firstQuiet = ContinuousClock.now + .milliseconds(200)
        while !settled.get() && ContinuousClock.now < firstQuiet {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(
            !settled.get(),
            "the boundary let go of the payments the identity change forgot (\(context))"
        )

        // One payment lands; the other is still held. A boundary that went back to the table after
        // the one it was awaiting would find it empty and return here, the other still to come.
        payingRelease[first]?.set(true)
        let answerDue = ContinuousClock.now + patience
        while payingAnswered[first]?.get() != true && ContinuousClock.now < answerDue {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(payingAnswered[first]?.get() == true, "control: \(first) was answered (\(context))")
        #expect(payingAnswered[second]?.get() == false, "control: \(second) is held (\(context))")
        let secondQuiet = ContinuousClock.now + .milliseconds(200)
        while !settled.get() && ContinuousClock.now < secondQuiet {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(
            !settled.get(),
            "the boundary returned with a payment out at its call still held (\(context))"
        )

        payingRelease[second]?.set(true)
        let settleDue = ContinuousClock.now + patience
        while !settled.get() && ContinuousClock.now < settleDue {
            try await Task.sleep(for: .milliseconds(1))
        }
        // The final readings are the verdict; awaiting a task that never ended would turn a
        // boundary that never returns into a suite that never ends.
        guard settled.get(), lateSettled.get() else {
            Issue.record("a boundary never returned once every payment had landed (\(context))")
            return
        }
        _ = await boundary.value
        _ = await late.value

        #expect(payingAnswered.values.allSatisfy { $0.get() })
        #expect(reads["a"]?.count == 2, "the debt on a was paid once (\(context))")
        #expect(reads["b"]?.count == 2, "the debt on b was paid once (\(context))")
        // What the forgotten payments brought back was refused where it landed.
        #expect(store.memos.isEmpty, "a forgotten payment reached the list (\(context))")
    }
}
