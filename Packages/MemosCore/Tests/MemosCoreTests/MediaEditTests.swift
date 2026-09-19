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
private let appendChunkOperation = "append_chunk_api_uploads__upload_uid__patch"
private let uploadOffsetOperation = "upload_offset_api_uploads__upload_uid__head"

/// What the server answers a `HEAD /api/uploads/{uid}` with: a status, the offset in a HEADER, and
/// NO body at all. Built by hand rather than through `Stub.json` because the shape is the point —
/// the generated client is asked to read a header off a response that carries nothing else, which
/// is exactly what the contract now publishes and what the server has always sent.
private func offsetAnswer(_ offset: Int) -> (HTTPResponse, HTTPBody?) {
    offsetAnswer(raw: String(offset))
}

/// The same answer with a header that is not a number — a session whose position cannot be read.
private func offsetAnswer(raw: String) -> (HTTPResponse, HTTPBody?) {
    var response = HTTPResponse(status: .ok)
    response.headerFields[HTTPField.Name("Upload-Offset")!] = raw
    return (response, nil)
}

/// The server refusing a chunk that does not start where it holds: the 409 the contract answers an
/// offset gap with, body and all.
private func offsetGap() -> (HTTPResponse, HTTPBody?) {
    Stub.json(#"{"detail":"Offset gap; re-sync via HEAD"}"#, status: .conflict)
}

/// Keeps a request open until the test lets it go. `nonisolated`, because it is called from inside
/// the scripted transport, which the client runs off the main actor.
private func hold(until release: LockedValue<Bool>) async throws {
    while !release.get() {
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// The offset a chunk request declared, as the server reads it.
private func sentOffset(_ request: HTTPRequest) -> Int {
    let field = request.headerFields.first { $0.name.canonicalName == "upload-offset" }
    return Int(field?.value ?? "-1") ?? -1
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

/// Editing a memo and attaching media to it in the same breath — the FOREGROUND lane, which is
/// deliberately not the outbox.
///
/// Two things are being held here. The request shape: files become upload sessions, and the memo
/// patch names those sessions in `upload_uids` (the server finalizes them as part of the write, so
/// nothing here calls `/finalize`). And the rollback: an edit with media either happens whole or
/// does not happen at all, because half of it is a memo somebody has to repair by hand.
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

    @Test("a picked file becomes an upload session the memo patch names")
    func editWithOneFile() async throws {
        let file = try stagedFile(bytes: 12)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let sent = LockedValue<[String: Any]>([:])
        let started = LockedValue<[String: Any]>([:])
        let chunkBytes = LockedValue<Int>(0)
        let finalizes = Counter()
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                started.set(try await Stub.body(body))
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            case appendChunkOperation:
                let data = try await Stub.bytes(body)
                chunkBytes.set(chunkBytes.get() + data.count)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: data.count))
            case patchMemoOperation:
                sent.set(try await Stub.body(body))
                return Stub.json(Stub.memo(uid: "a", content: "with a photo"))
            case "finalize_upload_api_uploads__upload_uid__finalize_post":
                finalizes.increment()
                return Stub.empty(.ok)
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a",
            content: "with a photo",
            attaching: [file],
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        #expect(saved)
        #expect(started.get()["filename"] as? String == "picked.jpg")
        #expect(started.get()["mime"] as? String == "image/jpeg")
        #expect(started.get()["size"] as? Int == 12)
        #expect(chunkBytes.get() == 12)
        #expect(sent.get()["upload_uids"] as? [String] == ["u1"])
        // The memo write is what finalizes a pending upload (memos-ng "finalize-on-post"); a
        // client that finalized for itself would produce an attachment belonging to no memo.
        #expect(finalizes.count == 0)
    }

    @Test("a file larger than one chunk is sent in the pieces the server asks for")
    func chunksFollowTheServer() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let offsets = LockedValue<[Int]>([])
        let received = LockedValue<Int>(0)
        let client = Stub.client { request, body, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case appendChunkOperation:
                offsets.set(offsets.get() + [sentOffset(request)])
                let data = try await Stub.bytes(body)
                received.set(received.get() + data.count)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: received.get()))
            case patchMemoOperation:
                return Stub.json(Stub.memo(uid: "a"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "big", attaching: [file], using: client.handle, baseURL: Stub.baseURL
        ).isSaved

        #expect(saved)
        // Three chunks: 4, 4, 2 — each starting where the SERVER said it now holds up to, which is
        // the only number a resume could ever agree with.
        #expect(offsets.get() == [0, 4, 8])
        #expect(received.get() == 10)
    }

    @Test("an upload that fails leaves the memo untouched and never patches it")
    func failedUploadDoesNotPatch() async throws {
        let file = try stagedFile(bytes: 8)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let patches = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            case appendChunkOperation:
                return Stub.empty(.internalServerError)
            case patchMemoOperation:
                patches.increment()
                return Stub.json(Stub.memo(uid: "a", content: "never"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a",
            content: "never",
            attaching: [file],
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        #expect(!saved)
        // THE rollback: no patch was ever sent, so the memo still says what it said. Half an edit
        // — new text with the photo missing — is the state nobody can repair from the app.
        #expect(patches.count == 0)
        #expect(store.memos[0].content == "hello")
        #expect(store.lastError != nil)
    }

    @Test("a patch refused after the uploads leaves the memo as it was")
    func refusedPatchLeavesTheMemo() async throws {
        let file = try stagedFile(bytes: 4)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            case appendChunkOperation:
                let data = try await Stub.bytes(body)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: data.count))
            case patchMemoOperation:
                return Stub.empty(.conflict)
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a",
            content: "refused",
            attaching: [file],
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        #expect(!saved)
        #expect(store.memos[0].content == "hello")
        #expect(store.memos[0].attachments.isEmpty)
        #expect(store.lastError != nil)
    }

    @Test("a 401 during an upload ends the session")
    func unauthorizedUploadEndsTheSession() async throws {
        let file = try stagedFile(bytes: 4)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let ended = Counter()
        let store = TimelineStore(onUnauthorized: { _ in
            ended.increment()
            return .endedSession
        })
        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.empty(.unauthorized)
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.edit(
            uid: "a", content: "no", attaching: [file], using: client.handle, baseURL: Stub.baseURL
        )

        // The upload lane wraps the API's own error to say which step failed; the wrapping must
        // not cost a 401 its identity, or a dead credential never ends the session.
        #expect(ended.count == 1)
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
    /// A save is not the only thing that can happen while a save is in flight — a second one can
    /// be submitted before the first one's answer arrives, and this store may not lean on a screen
    /// to prevent that. The first save then finishes and tidies up, and what it clears is the key
    /// belonging to the edit that is STILL RUNNING. If that one's response is lost, its retry finds
    /// nothing, mints a fresh key, and applies the same edit again — the same files attached twice,
    /// which is the exact harm the key exists to prevent.
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
        // Submitted while the first is still out: it mints its own key into the slot.
        let second = await store.edit(
            uid: "a", content: "second", using: client.handle, baseURL: Stub.baseURL
        ).isSaved
        #expect(!second, "control: the second save failed, so it is the one with a retry to make")
        release.set(true)
        #expect(
            await first.value.isSaved, "control: the first save landed, which is what tidies up")

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
    /// Two saves of identical fields share one key, and that is correct — they are one logical
    /// edit, and the second is answered as a replay of the first rather than applied twice. But
    /// then the FIRST one's answer arriving would release a key the second is still presenting; if
    /// the second's response is lost, its retry mints a fresh key and the same files are attached
    /// a second time. So the key is released only once nothing is still using it.
    @Test("a save landing while an identical one is still in flight keeps their shared key")
    func anIdenticalSaveStillInFlightKeepsTheKey() async throws {
        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let calls = LockedValue<Int>(0)
        let releaseFirst = LockedValue<Bool>(false)
        let releaseSecond = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            keys.set(keys.get() + [(try await Stub.body(body))["edit_key"] as? String ?? ""])
            let call = calls.get() + 1
            calls.set(call)
            switch call {
            case 1:
                try await hold(until: releaseFirst)
                return Stub.json(Stub.memo(uid: "a", content: "same"))
            case 2:
                // Held so it is STILL in flight when the first one lands, then lost.
                try await hold(until: releaseSecond)
                return Stub.empty(.internalServerError)
            default:
                return Stub.json(Stub.memo(uid: "a", content: "same"))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = Task {
            await store.edit(uid: "a", content: "same", using: client.handle, baseURL: Stub.baseURL)
        }
        while calls.get() < 1 {
            await Task.yield()
        }
        // Identical fields, so this one shares the first one's key rather than minting another.
        let second = Task {
            await store.edit(uid: "a", content: "same", using: client.handle, baseURL: Stub.baseURL)
        }
        while calls.get() < 2 {
            await Task.yield()
        }

        releaseFirst.set(true)
        #expect(
            await first.value.isSaved, "control: the first save landed, which is what tidies up")
        releaseSecond.set(true)
        #expect(!(await second.value).isSaved, "control: the second save is the one with a retry")

        // The retry of the save whose response was lost.
        await store.edit(uid: "a", content: "same", using: client.handle, baseURL: Stub.baseURL)

        let sent = keys.get()
        #expect(sent.count == 3)
        #expect(!sent[0].isEmpty, "the patch carried no edit key at all")
        #expect(sent[0] == sent[1], "control: identical saves share one key, which is the point")
        #expect(
            sent[2] == sent[0],
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

    // MARK: - the offset gap

    /// The one question a resume turns on: where does the session say it stands.
    ///
    /// The answer is a HEADER on a response with no body at all, which is what the server sends
    /// and what the contract now publishes. Nothing else in this file matters if this cannot be
    /// read, so it is asserted on its own rather than inferred from an upload that finished.
    @Test("the session's own offset is read back off the header of a bodyless answer")
    func theOffsetRouteIsReadFromItsHeader() async throws {
        let client = Stub.client { _, _, operation in
            operation == uploadOffsetOperation ? offsetAnswer(4) : Stub.empty(.ok)
        }
        let read = try await MediaUpload.offset(of: "u1", using: client)
        #expect(read == 4)
    }

    /// A session that does not answer is bounded by the DEADLINE, not by the URL loading system.
    ///
    /// The unreadable answer above fails as soon as it is parsed. A session that simply says
    /// nothing is the other half of the same case, and it used to be bounded only by the request
    /// timeout — around a minute of a Save frozen on a screen somebody is waiting at, at the end of
    /// which the upload is abandoned anyway. The stub answers eventually so this test cannot hang;
    /// what is asserted is that nothing waited for it.
    @Test("a session that will not say where it stands is given up on within the deadline")
    func theOffsetAskIsBounded() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let asks = LockedValue<Int>(0)
        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case uploadOffsetOperation:
                asks.set(asks.get() + 1)
                // Far longer than any deadline worth waiting: the answer that never comes in time.
                try await Task.sleep(for: .seconds(10))
                return offsetAnswer(4)
            default:
                return offsetGap()
            }
        }

        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: MediaUploadError.refused(.server(status: 409))) {
            try await MediaUpload.upload(
                file, using: client, offsetDeadline: .milliseconds(50)
            )
        }
        let elapsed = clock.now - started

        #expect(asks.get() == 1, "control: the session really was asked")
        // Generous, and still nowhere near the ten seconds the stub would have taken, let alone
        // the request timeout that used to be the only bound.
        #expect(elapsed < .seconds(3), "the upload waited for an answer that was not coming")
    }

    /// A position that cannot be read is not guessed at: the gap ends the edit, and ends it whole.
    ///
    /// Guessing would resend into the very gap the ask exists to close. The header here is not a
    /// number, which is the one way a session that DOES answer can still leave the client with
    /// nowhere to resume from.
    @Test("an offset gap the session cannot answer abandons the edit without patching the memo")
    func offsetGapAbortsWhenTheSessionCannotBeRead() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let offsets = LockedValue<[Int]>([])
        let heads = LockedValue<Int>(0)
        let patches = LockedValue<Int>(0)
        let client = Stub.client { request, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case uploadOffsetOperation:
                heads.set(heads.get() + 1)
                return offsetAnswer(raw: "nearly four")
            case appendChunkOperation:
                offsets.set(offsets.get() + [sentOffset(request)])
                return offsetGap()
            case patchMemoOperation:
                patches.set(patches.get() + 1)
                return Stub.json(Stub.memo(uid: "a"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a",
            content: "gapped",
            attaching: [file],
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        #expect(!saved)
        // The session IS asked where it stands: the contract's answer is attempted, not skipped.
        #expect(heads.get() == 1, "the gap was abandoned without asking the session anything")
        #expect(offsets.get() == [0], "the same chunk was resent into a gap nobody had resolved")
        // Whole, not half: no patch, so nothing is attached and the retry the person makes
        // carries the same edit key (`aRetryAfterAnAbortCannotDoubleApply`).
        #expect(patches.get() == 0)
        #expect(store.lastError != nil)
    }

    /// The resume itself, against a session that CAN answer — the shape the contract describes and
    /// the one this lane runs on the moment memos-ng sends it. Without this the resume would be
    /// code nothing exercises.
    @Test("a session that answers is re-synced, and the upload carries on from where it stands")
    func offsetGapIsResyncedWhenTheSessionAnswers() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let offsets = LockedValue<[Int]>([])
        let heads = LockedValue<Int>(0)
        let patches = LockedValue<Int>(0)
        let client = Stub.client { request, body, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case uploadOffsetOperation:
                heads.set(heads.get() + 1)
                // The server holds the first four bytes after all — the state the gap was about.
                return offsetAnswer(4)
            case appendChunkOperation:
                let offset = sentOffset(request)
                offsets.set(offsets.get() + [offset])
                guard offset != 0 else { return offsetGap() }
                let data = try await Stub.bytes(body)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: offset + data.count))
            case patchMemoOperation:
                patches.set(patches.get() + 1)
                return Stub.json(Stub.memo(uid: "a"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a",
            content: "gapped",
            attaching: [file],
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        #expect(saved, "an offset gap abandoned an edit the session had answered")
        #expect(heads.get() == 1, "the session was never asked where it stands")
        // 0 was refused; the re-sync said 4; the upload carried on from there to the end.
        #expect(offsets.get() == [0, 4, 8])
        // And the memo is patched ONCE, after the last byte landed — a resume that patched per
        // attempt would attach the file twice over.
        #expect(patches.get() == 1)
    }

    /// The other direction, and the dangerous one: a session claiming a position this upload has
    /// never reached.
    ///
    /// Resuming there would send the tail, call the upload whole and patch the memo to an
    /// attachment with a hole in the middle — bytes nobody ever sent and nobody would notice
    /// missing. The fence is what the client has actually put on the wire, so a re-sync may land
    /// anywhere up to the end of the chunk that was refused and nowhere beyond it.
    @Test("an offset past what was ever sent abandons the edit instead of skipping the bytes")
    func anOffsetPastWhatWasSentIsRefused() async throws {
        let file = try stagedFile(bytes: 12)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let offsets = LockedValue<[Int]>([])
        let patches = LockedValue<Int>(0)
        let client = Stub.client { request, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case uploadOffsetOperation:
                // Four bytes were sent and refused; the session says it holds eight.
                return offsetAnswer(8)
            case appendChunkOperation:
                offsets.set(offsets.get() + [sentOffset(request)])
                return offsetGap()
            case patchMemoOperation:
                patches.set(patches.get() + 1)
                return Stub.json(Stub.memo(uid: "a"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a",
            content: "skipped",
            attaching: [file],
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        #expect(!saved)
        #expect(offsets.get() == [0], "the upload resumed at a position it had never sent")
        #expect(patches.get() == 0, "a memo was patched over bytes that were never sent")
        #expect(store.lastError != nil)
    }

    /// A dead credential is not a conflict, wherever it is met.
    ///
    /// The offset ask is the one request on this lane whose failure the loop answers itself, and
    /// answering a 401 with its own sentence would leave the session running on a token the server
    /// has already rejected: the refusal has to reach the store carrying what it is
    /// (`StoreFailure.reportable`).
    @Test("a rejected credential on the offset ask keeps its identity instead of becoming a 409")
    func aRefusedOffsetAskKeepsItsIdentity() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case uploadOffsetOperation:
                return Stub.empty(.unauthorized)
            default:
                return offsetGap()
            }
        }

        await #expect(throws: MediaUploadError.refused(.unauthorized)) {
            try await MediaUpload.upload(file, using: client)
        }
    }

    @Test("a gap the server keeps reporting at the same place stops rather than spinning")
    func aGapThatDoesNotMoveStops() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let chunks = LockedValue<Int>(0)
        let patches = LockedValue<Int>(0)
        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case uploadOffsetOperation:
                // The offset it just refused — a server that is not converging. Answered in the
                // shape the contract describes, so the guard being tested is the one about
                // PROGRESS rather than the one about a session that cannot be read.
                return offsetAnswer(0)
            case appendChunkOperation:
                chunks.set(chunks.get() + 1)
                return offsetGap()
            case patchMemoOperation:
                patches.set(patches.get() + 1)
                return Stub.json(Stub.memo(uid: "a"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a",
            content: "stuck",
            attaching: [file],
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        #expect(!saved)
        #expect(chunks.get() == 1, "the same chunk was resent into a gap that had not moved")
        // And the edit is refused WHOLE: no patch, so nothing is half-applied and the retry the
        // person makes carries the same edit key.
        #expect(patches.get() == 0)
        #expect(store.lastError != nil)
    }

    /// What makes the abort above safe, and the one property the reviewer's alternative was
    /// protecting: a failed media edit leaves nothing attached, and the retry cannot apply twice.
    @Test("an edit abandoned mid-upload attaches nothing, and its retry carries the same key")
    func aRetryAfterAnAbortCannotDoubleApply() async throws {
        let file = try stagedFile(bytes: 8)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let uploads = LockedValue<Int>(0)
        let chunkFails = LockedValue<Bool>(true)
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                uploads.set(uploads.get() + 1)
                return Stub.json(
                    uploadOut(uid: "u\(uploads.get())", chunkSize: 64, received: 0),
                    status: .created
                )
            case appendChunkOperation:
                guard !chunkFails.get() else { return Stub.empty(.internalServerError) }
                let data = try await Stub.bytes(body)
                return Stub.json(
                    uploadOut(uid: "u\(uploads.get())", chunkSize: 64, received: data.count)
                )
            case patchMemoOperation:
                keys.set(keys.get() + [(try await Stub.body(body))["edit_key"] as? String ?? ""])
                return Stub.json(Stub.memo(uid: "a", content: "with a photo"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = await store.edit(
            uid: "a", content: "with a photo", attaching: [file], using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved
        #expect(!first)
        #expect(keys.get().isEmpty, "an edit whose upload failed still patched the memo")

        // The person taps Save again on the sheet that stayed open.
        chunkFails.set(false)
        let second = await store.edit(
            uid: "a", content: "with a photo", attaching: [file], using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        #expect(second)
        // Exactly one patch, and it carries the key the abandoned attempt would have used — so a
        // third attempt after a lost response replays rather than attaching the file twice.
        #expect(keys.get().count == 1)
        #expect(!keys.get()[0].isEmpty)
        #expect(uploads.get() == 2, "control: the retry really did upload the file again")
    }

    @Test("a server that names no chunk size gets one, not a loop that sends nothing")
    func chunkSizeFallback() {
        #expect(MediaUpload.usableChunkSize(0) == MediaUpload.fallbackChunkSize)
        #expect(MediaUpload.usableChunkSize(-1) == MediaUpload.fallbackChunkSize)
        // The control: a size the server DID name is the one used, so the fallback above is a
        // fallback rather than the only answer.
        #expect(MediaUpload.usableChunkSize(64) == 64)
    }

    @Test("a file that cannot be read is reported and nothing is sent")
    func unreadableFileIsReported() async {
        let missing = StagedSource(
            url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg"),
            filename: "gone.jpg",
            mime: "image/jpeg"
        )
        let store = TimelineStore()
        let requests = Counter()
        let client = Stub.client { _, _, operation in
            if operation != listMemosOperation { requests.increment() }
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a",
            content: "no",
            attaching: [missing],
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        #expect(!saved)
        #expect(requests.count == 0)
        #expect(store.lastError != nil)
    }

    /// The shape production actually meets on the offset ask, which the bare-token test above
    /// cannot reach: an INSTALLED credential, so its 401 is minted by `BearerAuthMiddleware` as a
    /// `CredentialRefusal` carrying the epoch the request presented, inside the generated client's
    /// envelope — never a `MediaUploadError`.
    ///
    /// The expectation is READ OFF the two lanes that already work, in the same setup and with the
    /// same credential, rather than constructed here: whatever `start` and `append` hand a caller
    /// for a 401, the offset ask must hand it the same thing. Renamed a 409, the refusal reaches
    /// no store, the epoch is lost, and the app carries on presenting a token the server is done
    /// with.
    @Test("an installed credential refused on the offset ask arrives as the refusal it is")
    func anInstalledCredentialsOffsetRefusalKeepsItsEpoch() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let credential = PresentedCredential("memos_pat_a")
        credential.install()

        func failure(of client: any APIProtocol) async -> (any Error)? {
            do {
                _ = try await MediaUpload.upload(file, using: client)
                return nil
            } catch {
                return error
            }
        }

        let refusedStart = Stub.client(token: credential) { _, _, _ in Stub.empty(.unauthorized) }
        let byStart = try #require(await failure(of: refusedStart), "the start was not refused")
        let onStart = try #require(StoreFailure.refusal(byStart))

        let refusedAppend = Stub.client(token: credential) { _, _, operation in
            operation == startUploadOperation
                ? Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
                : Stub.empty(.unauthorized)
        }
        let byAppend = try #require(await failure(of: refusedAppend), "the chunk was not refused")
        let onAppend = try #require(StoreFailure.refusal(byAppend))

        let heads = LockedValue<Int>(0)
        let refusedAsk = Stub.client(token: credential) { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case uploadOffsetOperation:
                heads.set(heads.get() + 1)
                return Stub.empty(.unauthorized)
            default:
                return offsetGap()
            }
        }
        let thrownByAsk = try #require(await failure(of: refusedAsk), "the ask was not refused")

        #expect(heads.get() == 1, "control: the session really was asked where it stands")
        #expect(onStart == onAppend, "control: the two lanes that work disagree with each other")
        #expect(
            StoreFailure.refusal(thrownByAsk) == onStart,
            "the offset ask lost the refusal the start and append lanes keep: \(thrownByAsk)"
        )
    }

    /// A session that opens by claiming more of the file than the file has.
    ///
    /// Taken at its word the loop never runs — the position is already past the end — and the
    /// upload reports success over a file of which nothing was ever sent, which the memo patch
    /// then names.
    @Test("a start that claims more than the whole file is not taken at its word")
    func aStartPositionBeyondTheFileAbandonsTheUpload() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let chunks = LockedValue<Int>(0)
        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(
                    uploadOut(uid: "u1", chunkSize: 4, received: 999), status: .created)
            case appendChunkOperation:
                chunks.set(chunks.get() + 1)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 4))
            default:
                return offsetGap()
            }
        }

        await #expect(throws: MediaUploadError.stalled) {
            try await MediaUpload.upload(file, using: client)
        }
        #expect(chunks.get() == 0, "control: nothing was sent from a position past the file")
    }

    /// The same number one step later: a chunk answered with more bytes than that chunk carried.
    ///
    /// Four went out and the session says it holds ninety-nine. Adopted, that ends the loop with
    /// most of the file never sent and the upload called whole.
    @Test("a chunk answered with more bytes than were sent abandons the upload")
    func anAppendAnswerBeyondWhatWasSentAbandonsTheUpload() async throws {
        let file = try stagedFile(bytes: 12)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case appendChunkOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 99))
            default:
                return offsetGap()
            }
        }

        await #expect(throws: MediaUploadError.stalled) {
            try await MediaUpload.upload(file, using: client)
        }
    }
}

/// The positions whose cost is not a failed upload but a dead process.
///
/// `Upload-Offset` and `bytes_received` are plain `integer` in the contract, with no minimum, and
/// the loop feeds the position it adopts to `FileHandle.seek(toOffset:)` — a `UInt64`. A negative
/// one TRAPS: the editor dies with the words somebody was in the middle of writing. Kept in their
/// own suite because a trap is a crash rather than a failed expectation, so each is meant to be
/// run on its own where the crash can be attributed.
@MainActor
@Suite("Upload positions that would take the app down")
struct UploadPositionTrapTests {
    @Test("a session answering the offset ask with a negative position is not resumed from")
    func aNegativeSyncedOffsetAbandonsTheUpload() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case uploadOffsetOperation:
                return offsetAnswer(-1)
            default:
                return offsetGap()
            }
        }

        await #expect(throws: MediaUploadError.stalled) {
            try await MediaUpload.upload(file, using: client)
        }
    }

    @Test("a start reporting a negative position is not resumed from")
    func aNegativeStartPositionAbandonsTheUpload() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let client = Stub.client { _, _, operation in
            operation == startUploadOperation
                ? Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: -1), status: .created)
                : offsetGap()
        }

        await #expect(throws: MediaUploadError.stalled) {
            try await MediaUpload.upload(file, using: client)
        }
    }
}
