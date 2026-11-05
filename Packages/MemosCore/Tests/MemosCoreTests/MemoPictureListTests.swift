import Foundation
import HTTPTypes
import MemosAPI
import MemosOutbox
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let listMemosOperation = "list_memos_api_memos_get"
private let patchMemoOperation = "patch_memo_api_memos__uid__patch"

/// The 422 the server answers an entry it cannot resolve with, one `detail` item, in the shape the
/// contract publishes.
private func rejectedEntry(_ type: String, uid: String, msg: String) -> String {
    #"{"detail":[{"loc":["body","attachment_uids","\#(uid)"],"msg":"\#(msg)","type":"\#(type)"}]}"#
}

/// The list a save STATES: which pictures the memo should end up with, in which order.
@MainActor
@Suite("A save that states the memo's picture list")
struct MemoPictureListTests {
    @Test("dropping one picture sends the whole remaining list in one patch")
    func aDroppedPictureLeavesTheRestNamedInOrder() async throws {
        let store = TimelineStore()
        let sent = LockedValue<[String: Any]>([:])
        let patches = Counter()
        let operations = LockedValue<[String]>([])
        let client = Stub.client { _, body, operation in
            operations.set(operations.get() + [operation])
            switch operation {
            case patchMemoOperation:
                patches.increment()
                sent.set(try await Stub.body(body))
                return Stub.json(
                    Stub.memo(
                        uid: "a", content: "kept",
                        attachments: [Stub.attachment(uid: "p2", status: "ready")]))
            default:
                return Stub.json(
                    Stub.page(
                        [
                            Stub.memo(
                                uid: "a", content: "kept",
                                attachments: [
                                    Stub.attachment(uid: "p1", status: "ready"),
                                    Stub.attachment(uid: "p2", status: "ready"),
                                ])
                        ], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "kept", listing: [.kept("p2")], using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        #expect(saved)
        #expect(patches.count == 1)
        #expect(sent.get()["attachment_uids"] as? [String] == ["p2"])
        // Removal is a property of the memo's list, not an act on the file: the picture stays in
        // the library and every other memo holding it keeps it.
        #expect(!operations.get().contains { $0.hasPrefix("delete_attachment") })
        #expect(store.memos[0].attachments.map(\.uid) == ["p2"])
    }

    @Test("a save that says nothing about pictures leaves the key out of the request")
    func noListMeansNoKey() async throws {
        let store = TimelineStore()
        let sent = LockedValue<[String: Any]>([:])
        let client = Stub.client { _, body, operation in
            switch operation {
            case patchMemoOperation:
                sent.set(try await Stub.body(body))
                return Stub.json(Stub.memo(uid: "a", content: "edited"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        ).isSaved

        #expect(saved)
        // ABSENT, not empty: `attachment_uids` REPLACES the memo's list, so an empty array sent on
        // every edit would strip the pictures off every memo edited from anywhere but the sheet.
        #expect(sent.get()["attachment_uids"] == nil)
        #expect(sent.get()["content"] as? String == "edited", "control: the patch was read at all")
    }

    @Test("a save that states an empty list clears the memo's pictures")
    func anEmptyListIsSentAsOne() async throws {
        let store = TimelineStore()
        let sent = LockedValue<[String: Any]>([:])
        let client = Stub.client { _, body, operation in
            switch operation {
            case patchMemoOperation:
                sent.set(try await Stub.body(body))
                return Stub.json(Stub.memo(uid: "a", content: "kept"))
            default:
                return Stub.json(
                    Stub.page(
                        [
                            Stub.memo(
                                uid: "a", content: "kept",
                                attachments: [Stub.attachment(uid: "p1", status: "ready")])
                        ], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "kept", listing: [], using: client.handle, baseURL: Stub.baseURL
        ).isSaved

        #expect(saved)
        // The empty list is the one statement that cannot be made by leaving the key out: the
        // sheet showing no pictures at all is a decision, and the server is told it.
        #expect(sent.get()["attachment_uids"] as? [String] == [String]())
    }

    @Test("two saves of the same words and different pictures are two edits")
    func aDifferentListIsADifferentEdit() async throws {
        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let lists = LockedValue<[[String]]>([])
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            let fields = try await Stub.body(body)
            keys.set(keys.get() + [fields["edit_key"] as? String ?? ""])
            lists.set(lists.get() + [fields["attachment_uids"] as? [String] ?? []])
            // Lost, not refused: an unresolved save is what makes the second tap a question about
            // keys at all.
            return Stub.empty(.internalServerError)
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.edit(
            uid: "a", content: "same", listing: [.kept("p1"), .kept("p2")],
            using: client.handle, baseURL: Stub.baseURL
        )
        // The same words, one picture removed before the second tap. A shared key would have the
        // server replay the first save and answer 200 while the removal went nowhere.
        await store.edit(
            uid: "a", content: "same", listing: [.kept("p1")], using: client.handle,
            baseURL: Stub.baseURL
        )

        let sent = keys.get()
        #expect(sent.count == 2, "a save with a different picture list never reached the wire")
        #expect(!sent[0].isEmpty, "control: the patch carried an edit key at all")
        #expect(sent[1] != sent[0], "two different picture lists shared one edit key")
        #expect(lists.get() == [["p1", "p2"], ["p1"]])
    }

    @Test("two saves of the same words and the same pictures are one request")
    func anIdenticalListJoinsTheSaveAlreadyOut() async throws {
        let store = TimelineStore()
        let calls = LockedValue<Int>(0)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            let call = calls.get() + 1
            calls.set(call)
            guard call == 1 else { return Stub.json(Stub.memo(uid: "a", content: "same")) }
            while !release.get() {
                try await Task.sleep(for: .milliseconds(1))
            }
            return Stub.json(Stub.memo(uid: "a", content: "same"))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = Task {
            await store.edit(
                uid: "a", content: "same", listing: [.kept("p1")], using: client.handle,
                baseURL: Stub.baseURL)
        }
        while calls.get() < 1 {
            await Task.yield()
        }
        let second = Task {
            await store.edit(
                uid: "a", content: "same", listing: [.kept("p1")], using: client.handle,
                baseURL: Stub.baseURL)
        }
        // Long enough for a request nothing holds back to have reached the transport.
        try await Task.sleep(for: .milliseconds(100))

        release.set(true)
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        #expect(calls.get() == 1, "the same save was put on the wire a second time")
        #expect(firstOutcome == secondOutcome, "one request, one answer, reported to both callers")
        #expect(firstOutcome.isSaved, "control: the save is the one that landed")
    }

    @Test("a retry of a save whose answer was lost presents that save's own key")
    func aRetryKeepsTheKeyOfItsList() async throws {
        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let calls = LockedValue<Int>(0)
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            keys.set(keys.get() + [(try await Stub.body(body))["edit_key"] as? String ?? ""])
            calls.set(calls.get() + 1)
            return calls.get() == 1
                ? Stub.empty(.internalServerError)
                : Stub.json(Stub.memo(uid: "a", content: "same"))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.edit(
            uid: "a", content: "same", listing: [.kept("p1")], using: client.handle,
            baseURL: Stub.baseURL
        )
        let saved = await store.edit(
            uid: "a", content: "same", listing: [.kept("p1")], using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved

        let sent = keys.get()
        #expect(saved)
        #expect(sent.count == 2)
        #expect(sent[0] == sent[1], "a retried save of the same list minted a second key")
    }

    @Test(
        "an entry the server will not resolve refuses the save and changes nothing",
        arguments: [
            "attachment_uid.missing", "attachment_uid.foreign_owner", "attachment_uid.other_memo",
            "attachment_uid.unresolvable_upload_uid",
        ])
    func aRefusedEntryRefusesTheWholeSave(type: String) async throws {
        let msg = "no picture here answers to p9"
        let store = TimelineStore()
        let client = Stub.client { _, _, operation in
            switch operation {
            case patchMemoOperation:
                return Stub.json(
                    rejectedEntry(type, uid: "p9", msg: msg), status: .unprocessableContent)
            default:
                return Stub.json(
                    Stub.page(
                        [
                            Stub.memo(
                                uid: "a", content: "kept",
                                attachments: [
                                    Stub.attachment(uid: "p1", status: "ready"),
                                    Stub.attachment(uid: "p2", status: "ready"),
                                ])
                        ], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let outcome = await store.edit(
            uid: "a", content: "kept", listing: [.kept("p1"), .kept("p9")], using: client.handle,
            baseURL: Stub.baseURL
        )

        #expect(outcome == .failed(.rejection))
        #expect(store.memos[0].attachments.map(\.uid) == ["p1", "p2"])
        // A definite refusal is not an uncertain save: the request was answered, so the sheet has
        // nothing to be frozen about — which is what these two failures, and only these two, mean.
        #expect(outcome != .failed(.transport(sent: true)))
        #expect(outcome != .failed(.serverFailure))
        // The server's words name the picture, and this app does not repeat them: the refusal is
        // carried as a case with no payload, so there is nowhere for the sentence to be.
        #expect(!String(describing: outcome).contains(msg))
        #expect(
            rejectedEntry(type, uid: "p9", msg: msg).contains(msg),
            "control: the envelope under test carried the sentence")
    }
}
