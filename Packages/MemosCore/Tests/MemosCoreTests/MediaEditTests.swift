import Foundation
import HTTPTypes
import MemosAPI
import MemosOutbox
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let listMemosOperation = "list_memos_api_memos_get"
private let patchMemoOperation = "patch_memo_api_memos__uid__patch"
private let startUploadOperation = "start_upload_api_uploads_post"

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
private func stagedFile(bytes: Int, named name: String = "picked.jpg") throws -> StagedSource {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString)-\(name)")
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return StagedSource(url: url, filename: name, mime: "image/jpeg")
}

/// Editing a memo, with and without media.
///
/// An edit without files is the direct PATCH, keyed per Save so a retry is one edit. An edit that
/// adds files is not sent from here at all (MEMNG-954): it is written to the outbox as an edit job,
/// whose own suite (MemosOutboxTests) holds the uploads and the PATCH that names them.
@MainActor
@Suite("Editing a memo with media")
struct MediaEditTests {
    @Test("an edit with no files sends no upload_uids at all")
    func editWithoutFilesNamesNoUploads() async throws {
        let store = TimelineStore()
        let sent = LockedValue<[String: Any]>([:])
        let uploads = Counter()
        let client = Stub.client { _, body, operation in
            switch operation {
            case patchMemoOperation:
                sent.set(try await Stub.body(body))
                return Stub.json(Stub.memo(uid: "a", content: "edited"))
            case startUploadOperation:
                uploads.increment()
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        ).isSaved

        #expect(saved)
        #expect(sent.get()["content"] as? String == "edited")
        // ABSENT, not empty: `upload_uids` on a patch ADDS attachments, so an array sent on every
        // edit would be a field the server has to ignore rather than a statement about this one.
        #expect(sent.get()["upload_uids"] == nil)
        #expect(uploads.count == 0)
        #expect(store.memos[0].content == "edited")
    }

    /// An edit that adds files is not sent from the timeline (MEMNG-954): the store writes it to
    /// the outbox as an edit job and answers once it is persisted. Pinned on BOTH sides: the
    /// generated client sees no upload and no patch, and the real repository holds one job naming
    /// the memo, carrying the edit's words, its file, a minted edit key and the picture list with
    /// the added file resolved to that file.
    @Test("an edit with files becomes an outbox edit job, and the store sends nothing itself")
    func editWithFilesIsQueued() async throws {
        let file = try stagedFile(bytes: 12)
        defer { try? FileManager.default.removeItem(at: file.url) }
        let (root, repository, outbox) = try editOutbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TimelineStore()
        let sent = LockedValue<[String]>([])
        let client = Stub.client { _, _, operation in
            sent.set(sent.get() + [operation])
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            case patchMemoOperation:
                return Stub.json(Stub.memo(uid: "a", content: "edited"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        sent.set([])

        let outcome = await store.edit(
            uid: "a", content: "edited", attaching: [file],
            listing: [.kept("p1"), .uploading(0)], through: outbox,
            using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome.isSaved)
        #expect(sent.get().isEmpty, "the store sent \(sent.get()) itself")
        let jobs = try await repository.loadJobs()
        #expect(jobs.count == 1)
        let job = try #require(jobs.first)
        #expect(job.resolvedMemoUID == "a")
        #expect(job.content == "edited")
        #expect(job.files.count == 1)
        #expect(job.files.allSatisfy { $0.stagedForEdit == true })
        #expect(job.editKey?.isEmpty == false, "the job was written without an edit key")
        #expect(job.memoEdit?.pictures == [.kept("p1"), .added(job.files[0].id)])
        #expect(job.memoEdit?.statesDate == false)
    }

    /// MEMNG-1187 item 3: an edit job sends its audience LATER — after the sheet has closed, when
    /// the memo may have been narrowed elsewhere — so the one it carries must be one no later state
    /// can make a widening: Private, or an audience the person confirmed. A narrowing to anything
    /// wider than Private is asked at the Save, and nothing is written until it is answered.
    @Test("an edit job's audience that could widen later is asked before the job is written")
    func anEditJobsDeferredAudienceIsAsked() async throws {
        let file = try stagedFile(bytes: 12)
        defer { try? FileManager.default.removeItem(at: file.url) }
        let (root, repository, outbox) = try editOutbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TimelineStore()
        let client = Stub.client { _, _, _ in
            Stub.json(Stub.page([Stub.memo(uid: "a", visibility: "PUBLIC")]))
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let narrowing = VisibilityChange.cleared(.protected, from: .public)
        #expect(!narrowing.confirmed, "the case needs a narrowing nobody was asked about")

        let asked = await store.edit(
            uid: "a", content: "edited", attaching: [file],
            listing: [.kept("p1"), .uploading(0)], visibility: narrowing, through: outbox,
            using: client.handle, baseURL: Stub.baseURL
        )

        guard case .ask(let question) = asked else {
            Issue.record("a deferred Protected was written unasked: \(asked)")
            return
        }
        #expect(question.to == .protected)
        #expect(try await repository.loadJobs().isEmpty, "the job was written before the answer")

        let answered = await store.edit(
            uid: "a", content: "edited", attaching: [file],
            listing: [.kept("p1"), .uploading(0)], visibility: question.confirmed(),
            through: outbox, using: client.handle, baseURL: Stub.baseURL
        )
        #expect(answered == .saved)
        let job = try #require(try await repository.loadJobs().first)
        #expect(job.pendingEdit?.visibility == "PROTECTED")
    }

    /// The control: Private is never wider than any audience the memo can be given meanwhile.
    @Test("an edit job narrowing its memo to Private is written without a question")
    func anEditJobNarrowingToPrivateIsNotAsked() async throws {
        let file = try stagedFile(bytes: 12)
        defer { try? FileManager.default.removeItem(at: file.url) }
        let (root, repository, outbox) = try editOutbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TimelineStore()
        let client = Stub.client { _, _, _ in
            Stub.json(Stub.page([Stub.memo(uid: "a", visibility: "PUBLIC")]))
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let outcome = await store.edit(
            uid: "a", content: "edited", attaching: [file],
            listing: [.kept("p1"), .uploading(0)],
            visibility: VisibilityChange.cleared(.private, from: .public), through: outbox,
            using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .saved)
        let job = try #require(try await repository.loadJobs().first)
        #expect(job.pendingEdit?.visibility == "PRIVATE")
    }

    /// A store with one memo, a real outbox, and an edit job for that memo already written by the
    /// store itself. Answers the store, the client's log of operations (cleared after the
    /// enqueue), the repository, the outbox and the cleanup.
    private func storeOwingAnEdit(listing memos: [String] = [Stub.memo(uid: "a")]) async throws
        -> (
            TimelineStore, any APIProtocol, LockedValue<[String]>, OutboxRepository, Outbox,
            () -> Void
        )
    {
        let file = try stagedFile(bytes: 12)
        let (root, repository, outbox) = try editOutbox()
        let store = TimelineStore()
        let sent = LockedValue<[String]>([])
        let client = Stub.client { _, _, operation in
            sent.set(sent.get() + [operation])
            switch operation {
            case patchMemoOperation:
                return Stub.json(Stub.memo(uid: "a", content: "typo fixed"))
            default:
                return Stub.json(Stub.page(memos))
            }
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let queued = await store.edit(
            uid: "a", content: "edited", attaching: [file],
            listing: [.kept("p1"), .uploading(0)], through: outbox,
            composedUnder: alice, using: client.handle, baseURL: Stub.baseURL
        )
        #expect(queued == .saved, "the first edit job was not written: \(queued)")
        sent.set([])
        return (
            store, client, sent, repository, outbox,
            {
                try? FileManager.default.removeItem(at: file.url)
                try? FileManager.default.removeItem(at: root)
            }
        )
    }

    private var alice: AccountBinding {
        AccountBinding(serverBaseURL: Stub.baseURL, ownerSubject: "alice")
    }

    /// Invariant 1 on the edit job (MEMNG-954): the job froze the memo's words and its whole
    /// picture list when it was written, so a words-only edit sent beside it would be undone by its
    /// PATCH, or undo it. The STORE refuses it — not a button — and nothing goes on the wire.
    @Test("a direct edit while the memo's edit job is still queued is refused and sends nothing")
    func directEditBehindAnEditJobIsRefused() async throws {
        let (store, client, sent, repository, outbox, cleanUp) = try await storeOwingAnEdit()
        defer { cleanUp() }

        let outcome = await store.edit(
            uid: "a", content: "typo fixed", through: outbox, composedUnder: alice,
            using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .failed(.editPending))
        #expect(sent.get().isEmpty, "a refused edit sent \(sent.get())")
        let jobs = try await repository.loadJobs()
        #expect(jobs.count == 1)
        #expect(jobs.first?.content == "edited", "the refused edit reached the queued job")
    }

    /// Two overlapping edits that both add files are ONE job: the second is refused, never queued
    /// beside the first (whose PATCH would drop the second one's picture, or the other way round).
    @Test("two overlapping edits with files of one memo are one job: the second is refused")
    func overlappingFileEditsAreOneJob() async throws {
        let first = try stagedFile(bytes: 12)
        let second = try stagedFile(bytes: 14)
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }
        let (root, repository, outbox) = try editOutbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TimelineStore()
        let sent = LockedValue<[String]>([])
        let client = Stub.client { _, _, operation in
            sent.set(sent.get() + [operation])
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        sent.set([])

        async let one = store.edit(
            uid: "a", content: "one", attaching: [first], listing: [.uploading(0)],
            through: outbox, composedUnder: alice, using: client.handle, baseURL: Stub.baseURL)
        async let two = store.edit(
            uid: "a", content: "two", attaching: [second], listing: [.uploading(0)],
            through: outbox, composedUnder: alice, using: client.handle, baseURL: Stub.baseURL)
        let outcomes = await [one, two]

        #expect(outcomes.filter { $0 == .saved }.count == 1, "\(outcomes)")
        #expect(outcomes.filter { $0 == .failed(.editPending) }.count == 1, "\(outcomes)")
        #expect(try await repository.loadJobs().count == 1)
        #expect(sent.get().isEmpty, "the store sent \(sent.get()) itself")
    }

    /// The refusal lasts exactly as long as the job: a finished job is removed from the queue, and
    /// the memo takes an edit again — the direct PATCH, sent once.
    @Test("once the memo's edit job has finished, the memo can be edited again")
    func editAllowedAfterTheJobFinished() async throws {
        let (store, client, sent, repository, outbox, cleanUp) = try await storeOwingAnEdit()
        defer { cleanUp() }
        let job = try #require(try await repository.loadJobs().first)
        #expect(await repository.delete(job, ifStillCurrent: job))

        let outcome = await store.edit(
            uid: "a", content: "typo fixed", through: outbox, composedUnder: alice,
            using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .saved)
        #expect(sent.get().filter { $0 == patchMemoOperation }.count == 1)
    }

    /// A task tick is a whole content PATCH, and the edit job froze the memo's words: a tick sent
    /// beside it would be undone by the job's later PATCH. The STORE refuses it inside the memo's
    /// line, nothing goes on the wire, and the optimistic tick goes back (review round 2).
    @Test("a task tick while the memo's edit job is still queued is refused and sends nothing")
    func tickBehindAnEditJobIsRefused() async throws {
        let (store, client, sent, repository, outbox, cleanUp) = try await storeOwingAnEdit(
            listing: [Stub.memo(uid: "a", content: "- [ ] milk")])
        defer { cleanUp() }

        let ticked = await store.toggleTask(
            at: 0, in: "a", through: outbox, using: client.handle, baseURL: Stub.baseURL)

        #expect(!ticked)
        #expect(sent.get().isEmpty, "a refused tick sent \(sent.get())")
        #expect(store.memos.first?.content == "- [ ] milk", "the refused tick stayed on the row")
        let jobs = try await repository.loadJobs()
        #expect(jobs.count == 1)
        #expect(jobs.first?.content == "edited")
    }

    /// The control: once the job is gone the same tick goes out, once.
    @Test("a task tick once the memo's edit job has finished sends one PATCH")
    func tickAllowedAfterTheJobFinished() async throws {
        let (store, client, sent, repository, outbox, cleanUp) = try await storeOwingAnEdit(
            listing: [Stub.memo(uid: "a", content: "- [ ] milk")])
        defer { cleanUp() }
        let job = try #require(try await repository.loadJobs().first)
        #expect(await repository.delete(job, ifStillCurrent: job))

        let ticked = await store.toggleTask(
            at: 0, in: "a", through: outbox, using: client.handle, baseURL: Stub.baseURL)

        #expect(ticked)
        #expect(sent.get().filter { $0 == patchMemoOperation }.count == 1, "\(sent.get())")
    }

    /// The refusal is the memo's that owes the job, no other's: a tick on a second memo goes out
    /// while the first one's job is still queued.
    @Test("a task tick on another memo is not held by this memo's edit job")
    func tickOnAnotherMemoIsNotHeld() async throws {
        let (store, client, sent, _, outbox, cleanUp) = try await storeOwingAnEdit(
            listing: [
                Stub.memo(uid: "a", content: "- [ ] milk"),
                Stub.memo(uid: "b", content: "- [ ] eggs"),
            ])
        defer { cleanUp() }

        let ticked = await store.toggleTask(
            at: 0, in: "b", through: outbox, using: client.handle, baseURL: Stub.baseURL)

        #expect(ticked)
        #expect(sent.get().filter { $0 == patchMemoOperation }.count == 1, "\(sent.get())")
    }

    /// The job's PATCH carries the audience its sheet stated, so a change of audience made
    /// beside it could be put back by it: refused the same way, with nothing sent.
    @Test("a visibility change while the memo's edit job is still queued is refused")
    func visibilityBehindAnEditJobIsRefused() async throws {
        let (store, client, sent, repository, outbox, cleanUp) = try await storeOwingAnEdit(
            listing: [Stub.memo(uid: "a", visibility: "PUBLIC")])
        defer { cleanUp() }

        let outcome = await store.setVisibility(
            VisibilityChange.cleared(.private, from: .public), uid: "a", through: outbox,
            using: client.handle, baseURL: Stub.baseURL)

        #expect(outcome == .failed(.editPending))
        #expect(sent.get().isEmpty, "a refused visibility change sent \(sent.get())")
        #expect(store.memos.first?.visibility == .public)
        #expect(try await repository.loadJobs().count == 1)
    }

    /// The control: once the job is gone the same change goes out, once.
    @Test("a visibility change once the memo's edit job has finished sends one PATCH")
    func visibilityAllowedAfterTheJobFinished() async throws {
        let (store, client, sent, repository, outbox, cleanUp) = try await storeOwingAnEdit(
            listing: [Stub.memo(uid: "a", visibility: "PUBLIC")])
        defer { cleanUp() }
        let job = try #require(try await repository.loadJobs().first)
        #expect(await repository.delete(job, ifStillCurrent: job))

        let outcome = await store.setVisibility(
            VisibilityChange.cleared(.private, from: .public), uid: "a", through: outbox,
            using: client.handle, baseURL: Stub.baseURL)

        #expect(outcome == .saved)
        #expect(sent.get().filter { $0 == patchMemoOperation }.count == 1, "\(sent.get())")
    }

    /// The job is bound to the account the sheet was saved under (review: never `nil`): saved
    /// after the device moved to another account, it is refused and nothing is persisted, so these
    /// words can never be sent into the other account's memo.
    @Test("an edit with files saved under an account no longer signed in persists nothing")
    func editJobUnderAStaleAccountPersistsNothing() async throws {
        let file = try stagedFile(bytes: 12)
        defer { try? FileManager.default.removeItem(at: file.url) }
        let (root, repository, outbox) = try editOutbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TimelineStore()
        let client = Stub.client { _, _, _ in Stub.json(Stub.memoList(["a"], nextCursor: nil)) }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let outcome = await store.edit(
            uid: "a", content: "edited", attaching: [file], listing: [.uploading(0)],
            through: outbox,
            composedUnder: AccountBinding(serverBaseURL: Stub.baseURL, ownerSubject: "bob"),
            using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .failed(.storage))
        #expect(try await repository.loadJobs().isEmpty)
    }

    /// The other half of the same line: with nowhere to queue the edit, it is refused as a storage
    /// failure and nothing goes up from here instead — there is no foreground fallback any more.
    @Test("an edit with files and no queue is refused as storage, with nothing sent")
    func editWithFilesAndNoQueueSendsNothing() async throws {
        let file = try stagedFile(bytes: 12)
        defer { try? FileManager.default.removeItem(at: file.url) }
        let store = TimelineStore()
        let sent = LockedValue<[String]>([])
        let client = Stub.client { _, _, operation in
            sent.set(sent.get() + [operation])
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        sent.set([])

        let outcome = await store.edit(
            uid: "a", content: "edited", attaching: [file], using: client.handle,
            baseURL: Stub.baseURL
        )

        #expect(outcome == .failed(.storage))
        #expect(sent.get().isEmpty)
        #expect(store.memos[0].content != "edited")
    }

    // MARK: - the retry token

    /// The whole point of an edit key: a Save that is repeated is ONE edit, and a Save that is
    /// different is another. Without it a retried media edit is refused outright (the first attempt
    /// consumed the uploads); with it reused too eagerly, new words would be answered as a replay
    /// of the old ones and silently go nowhere.
    @Test("one Save keeps one edit key across its retries, and a different Save gets another")
    func editKeysIdentifyOneSave() async throws {
        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let patches = LockedValue<Int>(0)
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            patches.set(patches.get() + 1)
            keys.set(keys.get() + [(try await Stub.body(body))["edit_key"] as? String ?? ""])
            // The first three attempts fail AFTER the request was made — the ambiguous case, where
            // the client cannot know whether the edit landed.
            return patches.get() <= 3
                ? Stub.empty(.internalServerError)
                : Stub.json(Stub.memo(uid: "a", content: "two"))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.edit(uid: "a", content: "one", using: client.handle, baseURL: Stub.baseURL)
        // The same Save, tapped again.
        await store.edit(uid: "a", content: "one", using: client.handle, baseURL: Stub.baseURL)
        // A DIFFERENT Save, while the previous one is still unresolved: the words were changed
        // before the second tap. Sharing the earlier key would have the server replay the earlier
        // edit and answer 200 while these words went nowhere.
        await store.edit(uid: "a", content: "two", using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "two", using: client.handle, baseURL: Stub.baseURL
        ).isSaved

        let sent = keys.get()
        #expect(saved)
        #expect(sent.count == 4)
        #expect(!sent[0].isEmpty, "the patch carried no edit key at all")
        #expect(sent[0] == sent[1], "a retried Save minted a second key")
        #expect(sent[2] != sent[0], "a Save of different words reused the previous key")
        #expect(sent[3] == sent[2], "a retried Save minted a second key")
        // The contract's own shape: 8-64 characters of [A-Za-z0-9_-].
        for key in sent {
            #expect(key.count >= 8 && key.count <= 64)
            #expect(key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
    }

    /// The window a save closing carelessly opens.
    ///
    /// A save is not the only thing that can happen while a save is in flight — a second one with
    /// different words can be submitted before the first one's answer arrives, and this store may
    /// not lean on a screen to prevent that. It waits its turn instead of going out beside the
    /// first, and the key it mints when that turn comes is its own to keep: if ITS response is the
    /// one that is lost, the retry must find that key rather than mint a fresh one and apply the
    /// same edit again — the same files attached twice, which is the exact harm the key exists to
    /// prevent.
    @Test("a save that lands does not throw away the key of one still in flight")
    func aFinishedSaveKeepsAnotherSavesKey() async throws {
        let store = TimelineStore()
        let seen = LockedValue<[String: [String]]>([:])
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            let fields = try await Stub.body(body)
            let content = fields["content"] as? String ?? ""
            let key = fields["edit_key"] as? String ?? ""
            var recorded = seen.get()
            recorded[content, default: []].append(key)
            seen.set(recorded)
            guard content == "first" else { return Stub.empty(.internalServerError) }
            // The first save is held open, so the second one is submitted while it flies.
            entered.set(true)
            try await hold(until: release)
            return Stub.json(Stub.memo(uid: "a", content: "first"))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = Task {
            await store.edit(
                uid: "a",
                content: "first",
                using: client.handle,
                baseURL: Stub.baseURL
            )
        }
        while !entered.get() {
            await Task.yield()
        }
        // Submitted while the first is still out, and never awaited before that one is released:
        // it waits for the save ahead of it, so awaiting it here would be waiting for its turn.
        let second = Task {
            await store.edit(
                uid: "a", content: "second", using: client.handle, baseURL: Stub.baseURL
            )
        }
        // Long enough for a request nothing holds back to have reached the transport.
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen.get()["second"] == nil, "a save went out while an earlier one was unanswered")
        release.set(true)
        #expect(
            await first.value.isSaved, "control: the first save landed, which is what tidies up")
        #expect(
            !(await second.value).isSaved,
            "control: the second save failed, so it is the one with a retry to make"
        )

        // The retry of the SECOND save — the one whose response was lost.
        await store.edit(uid: "a", content: "second", using: client.handle, baseURL: Stub.baseURL)

        let secondKeys = seen.get()["second"] ?? []
        #expect(secondKeys.count == 2)
        #expect(
            secondKeys[0] == secondKeys[1],
            "a save landing threw away the key of the one still running, so its retry re-applied"
        )
        // Controls: the keys are real, and the two saves never shared one.
        #expect(!secondKeys[0].isEmpty)
        #expect(seen.get()["first"]?.first != secondKeys[0])
    }

    /// The other door into the same harm.
    ///
    /// Two saves of identical fields are one logical edit, and one request: the second joins the
    /// one already out and is given its answer. So there is a single key, and both callers are
    /// holding it — which is why a landing save may not release a key on its own account. If that
    /// one answer is lost, the retry must present the same key, or the same files are attached a
    /// second time.
    @Test("a save landing while an identical one is still in flight keeps their shared key")
    func anIdenticalSaveStillInFlightKeepsTheKey() async throws {
        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let calls = LockedValue<Int>(0)
        let releaseFirst = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            keys.set(keys.get() + [(try await Stub.body(body))["edit_key"] as? String ?? ""])
            let call = calls.get() + 1
            calls.set(call)
            guard call == 1 else { return Stub.json(Stub.memo(uid: "a", content: "same")) }
            // Held so the identical save is submitted while it is out, and then lost.
            try await hold(until: releaseFirst)
            return Stub.empty(.internalServerError)
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = Task {
            await store.edit(uid: "a", content: "same", using: client.handle, baseURL: Stub.baseURL)
        }
        while calls.get() < 1 {
            await Task.yield()
        }
        // Identical fields, so this one joins the save already out rather than sending beside it.
        let second = Task {
            await store.edit(uid: "a", content: "same", using: client.handle, baseURL: Stub.baseURL)
        }
        // Long enough for a request nothing holds back to have reached the transport.
        try await Task.sleep(for: .milliseconds(100))

        releaseFirst.set(true)
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        #expect(calls.get() == 1, "the same save was put on the wire a second time")
        #expect(firstOutcome == secondOutcome, "one request, one answer, reported to both callers")
        #expect(!firstOutcome.isSaved, "control: the save is the one with a retry to make")

        // The retry of the save whose response was lost.
        await store.edit(uid: "a", content: "same", using: client.handle, baseURL: Stub.baseURL)

        let sent = keys.get()
        #expect(sent.count == 2)
        #expect(!sent[0].isEmpty, "the patch carried no edit key at all")
        #expect(
            sent[1] == sent[0],
            "a save landing released a key an identical one was still presenting"
        )
    }

    @Test("the same words typed again after a save that worked are a new edit, not a replay")
    func aSuccessfulSaveEndsItsKey() async throws {
        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            keys.set(keys.get() + [(try await Stub.body(body))["edit_key"] as? String ?? ""])
            return Stub.json(Stub.memo(uid: "a", content: "one"))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.edit(uid: "a", content: "one", using: client.handle, baseURL: Stub.baseURL)
        await store.edit(uid: "a", content: "one", using: client.handle, baseURL: Stub.baseURL)

        // Held past the success, the second one would be answered as a replay of the first — a
        // 200, and the edit not applied — which is indistinguishable on screen from a save that
        // worked.
        #expect(keys.get().count == 2)
        #expect(keys.get()[0] != keys.get()[1])
    }
}

// MARK: - A real outbox for the edit job

/// A real repository on a scratch directory behind a real outbox, signed in so the edit can be
/// written. Its network answers 500 and moves no file, so whatever it tries is never the store's.
@MainActor
func editOutbox() throws -> (URL, OutboxRepository, Outbox) {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let credentials = EditSignedIn()
    let repository = try OutboxRepository(
        root: root, stillCurrent: { credentials.stillCurrent(epoch: $0) })
    let defaults = UserDefaults(suiteName: "media-edit-\(UUID().uuidString)") ?? .standard
    let outbox = Outbox(
        repository: repository, credentials: credentials, http: EditUnsent(),
        scheduler: EditNoChunks(), completion: MemoCompletionEndpoint(http: EditUnsent()),
        network: EditPath(), preferences: UploadPreferences(defaults: defaults))
    return (root, repository, outbox)
}

/// Signed in as alice on the stub server, for the whole test.
private struct EditSignedIn: OutboxCredentialsProviding {
    func currentCredentials() async -> OutboxCredentials? {
        OutboxCredentials(serverBaseURL: Stub.baseURL, ownerSubject: "alice", token: "t")
    }
    func isCurrent(_ credentials: OutboxCredentials) -> Bool { true }
    func stillCurrent(epoch: Int) -> Bool { true }
}

/// The outbox's network: a server error for anything it tries.
private struct EditUnsent: OutboxHTTPPerforming {
    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        OutboxHTTPResponse(statusCode: 500)
    }
}

/// No background transfers.
private struct EditNoChunks: OutboxChunkScheduling {
    func inFlight() async -> [OutboxTaskIdentity] { [] }
    func upload(
        _ request: URLRequest, fromFile file: URL, identity: OutboxTaskIdentity,
        under authority: SendAuthority, issuedUnder epoch: Int
    ) async {}
    func cancel(_ identities: [OutboxTaskIdentity]) async {}
    func cancelEveryTask() async {}
}

/// A usable path, never changing.
private struct EditPath: NetworkPathProviding {
    func currentPath() -> NetworkPath {
        NetworkPath(usesCellular: false, isExpensive: false, isConstrained: false)
    }
    func onPathChange(_ handler: @escaping OutboxTrigger) {}
}
