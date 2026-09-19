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
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case getMemoOperation:
                entered.set(true)
                try await hold(until: release)
                return Stub.json(
                    Stub.memo(
                        uid: "a", content: "old",
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

        #expect(store.memos.first?.content == "new")
        // What the read is FOR still lands: the tiers it reports are the freshest fact about that
        // file, and the save says nothing about them.
        #expect(store.memos.first?.attachments.first?.status == .ready)
    }

    @Test("a read that left before a save does not put the old tags back")
    func aHeldReadDoesNotRestoreTheTagsTheSaveReplaced() async throws {
        let store = TimelineStore()
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case getMemoOperation:
                entered.set(true)
                try await hold(until: release)
                return Stub.json(
                    taggedMemo(
                        uid: "a", content: "#old", tags: ["old"],
                        attachments: [Stub.attachment(uid: "p", status: "ready")]
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

    /// The row is stamped when the server's answer is APPLIED, not when the save's task ends, and
    /// the instant between the two is what tells those apart: `commit` has already put the row in
    /// the list and is still writing the picture of it down, so a read issued before the save can
    /// land there with the save unfinished.
    @Test("a read that lands while the row is being written down does not put the old words back")
    func aReadLandingWhileTheRowPersistsDoesNotRestoreTheOldText() async throws {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let persisting = LockedValue<Bool>(false)
        let persistRelease = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case getMemoOperation:
                entered.set(true)
                try await hold(until: release)
                return Stub.json(Stub.memo(uid: "a", content: "old"))
            case patchMemoOperation:
                return Stub.json(Stub.memo(uid: "a", content: "new"))
            default:
                return Stub.json(Stub.page([Stub.memo(uid: "a", content: "old")]))
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
        let reading = Task {
            await store.refreshMemo(uid: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        let saving = Task {
            await store.edit(uid: "a", content: "new", using: client.handle, baseURL: Stub.baseURL)
        }
        while !persisting.get() {
            await Task.yield()
        }
        release.set(true)
        _ = await reading.value
        persistRelease.set(true)
        _ = await saving.value

        #expect(store.memos.first?.content == "new")
    }
}
