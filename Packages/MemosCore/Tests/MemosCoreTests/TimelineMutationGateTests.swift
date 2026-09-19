import Foundation
import HTTPTypes
import MemosAPI
import MemosOutbox
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let patchMemoOperation = "patch_memo_api_memos__uid__patch"
private let deleteMemoOperation = "delete_memo_api_memos__uid__delete"
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

/// Long enough for a request that nothing holds back to reach the transport, so that "it never
/// arrived" is evidence rather than a race this test happened to win.
private func timeForARequestToArrive() async {
    try? await Task.sleep(for: .milliseconds(100))
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

/// One memo's mutations, one at a time.
///
/// A second Save, a delete of the memo somebody is editing, a tap repeated because the first one
/// looked ignored: nothing but this store can order those. A screen that disables its own button is
/// not a guard — the compose sheet, the detail view and the share extension all reach the same memo
/// through the same store, and a request already on the wire cannot be recalled by a view.
///
/// So the unfinished mutations of a memo are kept in arrival order. An arrival whose identity
/// equals the LAST of them is the same mutation submitted twice and joins it, receiving its answer;
/// anything else waits for everything ahead of it and is then sent.
@MainActor
@Suite("Serializing one memo's mutations")
struct TimelineMutationGateTests {
    @Test("a save submitted while another is out is not sent until that one has answered")
    func aQueuedSaveWaitsForTheSaveBeforeIt() async throws {
        let store = TimelineStore()
        let patched = LockedValue<[String]>([])
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            let content = (try await Stub.body(body))["content"] as? String ?? ""
            patched.set(patched.get() + [content])
            if content == "first" { try await hold(until: release) }
            return Stub.json(Stub.memo(uid: "a", content: content))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = Task {
            await store.edit(
                uid: "a", content: "first", using: client.handle, baseURL: Stub.baseURL
            )
        }
        while patched.get().isEmpty {
            await Task.yield()
        }
        let second = Task {
            await store.edit(
                uid: "a", content: "second", using: client.handle, baseURL: Stub.baseURL
            )
        }
        await timeForARequestToArrive()

        #expect(patched.get() == ["first"], "a save went out while an earlier one was unanswered")
        release.set(true)
        #expect(await first.value.isSaved)
        #expect(await second.value.isSaved)
        #expect(patched.get() == ["first", "second"])
        // The later words are the ones that stand: they were sent last and answered last.
        #expect(store.memos[0].content == "second")
    }

    @Test("two overlapping identical saves are one request, answered to both")
    func twoOverlappingIdenticalSavesAreOneRequest() async throws {
        let store = TimelineStore()
        let patched = LockedValue<[String]>([])
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            patched.set(patched.get() + [(try await Stub.body(body))["content"] as? String ?? ""])
            try await hold(until: release)
            return Stub.json(Stub.memo(uid: "a", content: "same"))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = Task {
            await store.edit(
                uid: "a", content: "same", using: client.handle, baseURL: Stub.baseURL
            )
        }
        while patched.get().isEmpty {
            await Task.yield()
        }
        let second = Task {
            await store.edit(
                uid: "a", content: "same", using: client.handle, baseURL: Stub.baseURL
            )
        }
        await timeForARequestToArrive()
        release.set(true)
        let firstOutcome = await first.value
        let secondOutcome = await second.value

        #expect(patched.get() == ["same"], "the same save was put on the wire twice")
        #expect(firstOutcome == secondOutcome, "one request, two answers")
        #expect(firstOutcome.isSaved, "control: the save landed")
        #expect(store.memos[0].content == "same")
    }

    @Test("two identical saves queued behind a different one are one request between them")
    func twoIdenticalSavesQueuedBehindADifferentOneAreOneRequest() async throws {
        let file = try stagedFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let patched = LockedValue<[String]>([])
        let uploads = Counter()
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                uploads.increment()
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            case appendChunkOperation:
                let data = try await Stub.bytes(body)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: data.count))
            case finalizeUploadOperation:
                return Stub.empty(.ok)
            case patchMemoOperation:
                let content = (try await Stub.body(body))["content"] as? String ?? ""
                patched.set(patched.get() + [content])
                if content == "first" { try await hold(until: release) }
                return Stub.json(Stub.memo(uid: "a", content: content))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = Task {
            await store.edit(
                uid: "a", content: "first", using: client.handle, baseURL: Stub.baseURL
            )
        }
        while patched.get().isEmpty {
            await Task.yield()
        }
        // One turn of the main actor each: the place in line is taken by synchronous code, before
        // either of these calls awaits anything, so this is all they need to be queued in order.
        let queued = Task {
            await store.edit(
                uid: "a", content: "queued", attaching: [file],
                using: client.handle, baseURL: Stub.baseURL
            )
        }
        await Task.yield()
        let identical = Task {
            await store.edit(
                uid: "a", content: "queued", attaching: [file],
                using: client.handle, baseURL: Stub.baseURL
            )
        }
        await Task.yield()
        release.set(true)
        #expect(await first.value.isSaved, "control: the save ahead of them landed")
        let queuedOutcome = await queued.value
        let identicalOutcome = await identical.value

        #expect(patched.get() == ["first", "queued"], "a save queued twice was sent twice")
        #expect(uploads.count == 1, "the joined save uploaded its file a second time")
        #expect(queuedOutcome == identicalOutcome, "one request, two answers")
        #expect(queuedOutcome.isSaved, "control: the queued save landed")
        #expect(store.memos[0].content == "queued")
    }

    @Test("a save identical to an earlier one is a new save when another came between them")
    func anIdenticalSaveAfterADifferentOneIsNotAJoin() async throws {
        let store = TimelineStore()
        let patched = LockedValue<[String]>([])
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            let content = (try await Stub.body(body))["content"] as? String ?? ""
            patched.set(patched.get() + [content])
            if content == "first" { try await hold(until: release) }
            return Stub.json(Stub.memo(uid: "a", content: content))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = Task {
            await store.edit(
                uid: "a", content: "first", using: client.handle, baseURL: Stub.baseURL
            )
        }
        while patched.get().isEmpty {
            await Task.yield()
        }
        // One turn of the main actor each: see the comment in the test above.
        let second = Task {
            await store.edit(
                uid: "a", content: "second", using: client.handle, baseURL: Stub.baseURL
            )
        }
        await Task.yield()
        let third = Task {
            await store.edit(
                uid: "a", content: "third", using: client.handle, baseURL: Stub.baseURL
            )
        }
        await Task.yield()
        // The words of the second save typed back after the third — a person undoing what they
        // just did, not a repeat of a save still in flight.
        let again = Task {
            await store.edit(
                uid: "a", content: "second", using: client.handle, baseURL: Stub.baseURL
            )
        }
        await Task.yield()
        release.set(true)
        #expect(await first.value.isSaved)
        #expect(await second.value.isSaved)
        #expect(await third.value.isSaved)
        #expect(await again.value.isSaved)

        #expect(
            patched.get() == ["first", "second", "third", "second"],
            "a save was joined to an earlier identical one that something else came after"
        )
        #expect(store.memos[0].content == "second", "the last save sent is not what stands")
    }

    @Test("two overlapping deletes of one memo are one request")
    func twoOverlappingDeletesAreOneRequest() async throws {
        let store = TimelineStore()
        let deletes = Counter()
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            guard operation == deleteMemoOperation else {
                return Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
            }
            deletes.increment()
            try await hold(until: release)
            return Stub.empty(.noContent)
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = Task { await store.delete(uid: "a", using: client.handle) }
        while deletes.count == 0 {
            await Task.yield()
        }
        let second = Task { await store.delete(uid: "a", using: client.handle) }
        await timeForARequestToArrive()
        release.set(true)
        let firstGone = await first.value
        let secondGone = await second.value

        #expect(deletes.count == 1, "a memo this app had already asked to delete was asked again")
        #expect(firstGone, "control: the delete landed")
        #expect(secondGone == firstGone, "one request, two answers")
        #expect(store.memos.map(\.uid) == ["b"])
    }

    @Test("a tick is refused while a save of the same memo is unfinished")
    func aTickIsRefusedWhileASaveOfTheSameMemoIsUnfinished() async throws {
        let store = TimelineStore()
        let patches = Counter()
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.page([Stub.memo(uid: "a", content: "- [ ] milk")]))
            }
            patches.increment()
            let content = (try await Stub.body(body))["content"] as? String ?? ""
            try await hold(until: release)
            return Stub.json(Stub.memo(uid: "a", content: content))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saving = Task {
            await store.edit(
                uid: "a", content: "new words", using: client.handle, baseURL: Stub.baseURL
            )
        }
        while patches.count == 0 {
            await Task.yield()
        }
        // A tap on the box of a memo whose words are being rewritten. The tick is a whole content
        // patch derived from the row as it stands, so it is refused outright rather than queued —
        // queued, it would send the person words they have just replaced.
        let ticked = Task {
            await store.toggleTask(at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        await timeForARequestToArrive()

        #expect(patches.count == 1, "the tick was sent while a save of that memo was unfinished")
        #expect(store.memos[0].content == "- [ ] milk", "a refused tick still moved the box")
        release.set(true)
        #expect(await saving.value.isSaved, "control: the save landed")
        #expect(
            !(await ticked.value),
            "the tick was taken while a save of that memo was unfinished"
        )
        #expect(store.memos[0].content == "new words")
    }

    @Test("a save joined while it is still uploading uploads its files once")
    func aJoinedSaveUploadsItsFilesOnce() async throws {
        let file = try stagedFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let uploads = Counter()
        let patches = Counter()
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                uploads.increment()
                // Held HERE rather than at the patch: the second save arrives while the first is
                // still in its upload, which is the window a gate taken after the upload leaves
                // open — and a file uploaded twice is an attachment posted twice.
                try await hold(until: release)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            case appendChunkOperation:
                let data = try await Stub.bytes(body)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: data.count))
            case finalizeUploadOperation:
                return Stub.empty(.ok)
            case patchMemoOperation:
                patches.increment()
                return Stub.json(Stub.memo(uid: "a", content: "with a photo"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = Task {
            await store.edit(
                uid: "a", content: "with a photo", attaching: [file],
                using: client.handle, baseURL: Stub.baseURL
            )
        }
        while uploads.count == 0 {
            await Task.yield()
        }
        let second = Task {
            await store.edit(
                uid: "a", content: "with a photo", attaching: [file],
                using: client.handle, baseURL: Stub.baseURL
            )
        }
        await timeForARequestToArrive()
        release.set(true)
        let firstOutcome = await first.value
        let secondOutcome = await second.value

        #expect(uploads.count == 1, "the joined save uploaded the same file a second time")
        #expect(patches.count == 1, "the joined save patched the memo a second time")
        #expect(firstOutcome == secondOutcome, "one request, two answers")
        #expect(firstOutcome.isSaved, "control: the save landed")
    }
}
