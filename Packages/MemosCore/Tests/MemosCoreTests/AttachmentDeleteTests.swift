import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

private let deleteAttachmentOperation = "delete_attachment_api_attachments__uid__delete"
private let listMemosOperation = "list_memos_api_memos_get"
private let getMemoOperation = "get_memo_api_memos__uid__get"
private let patchMemoOperation = "patch_memo_api_memos__uid__patch"

/// Removing ONE picture from a memo that is already posted.
///
/// The server hard-deletes an attachment — the row, the original and every derived tier — so this
/// store may only remove it locally once the server has said 204, and once it has said so the
/// picture must not come back. Both halves are asserted through the REAL generated client over a
/// scripted transport: the request this store builds, its path and its bearer, and every lane a
/// stale answer could arrive on afterwards.
@MainActor
@Suite("Attachment delete")
struct AttachmentDeleteTests {
    /// Keeps a request open until the test lets it go. `nonisolated static`, because it is called
    /// from inside the scripted transport, which the client runs off the main actor.
    private nonisolated static func hold(until release: LockedValue<Bool>) async throws {
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private nonisolated static func memo(_ uid: String, _ attachments: [String]) -> String {
        Stub.memo(
            uid: uid,
            attachments: attachments.map { Stub.attachment(uid: $0, status: "ready") }
        )
    }

    private nonisolated static func page(_ memos: [String]) -> (HTTPResponse, HTTPBody?) {
        Stub.json(Stub.page(memos))
    }

    /// The request itself: the right verb at the right path, carrying the credential the middleware
    /// attaches — which is what a hand-written stand-in for the client could never show.
    @Test("the delete goes to that one attachment, with the token on it")
    func theRequestIsADeleteOfThatAttachment() async {
        let seen = LockedValue<[String]>([])
        let authorization = LockedValue<String?>(nil)
        let client = Stub.client(token: { "memos_pat_abc" }) { request, _, operation in
            guard operation == deleteAttachmentOperation else {
                return Self.page([Self.memo("m1", ["a1", "a2"])])
            }
            seen.set(seen.get() + ["\(request.method.rawValue) \(request.path ?? "")"])
            authorization.set(request.headerFields[.authorization])
            return Stub.empty(.noContent)
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client)

        #expect(removed)
        #expect(seen.get() == ["DELETE /api/attachments/a1"], "the store sent \(seen.get())")
        #expect(authorization.get() == "Bearer memos_pat_abc")
    }

    @Test("a 204 removes exactly that attachment and leaves the memo where it was")
    func the204RemovesExactlyThatAttachment() async {
        let client = Stub.client { _, _, operation in
            operation == deleteAttachmentOperation
                ? Stub.empty(.noContent)
                : Self.page([
                    Self.memo("m1", ["a0"]),
                    Self.memo("m2", ["a1", "a2"]),
                    Self.memo("m3", ["a3"]),
                ])
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let removed = await store.deleteAttachment(uid: "a1", from: "m2", using: client)

        #expect(removed)
        #expect(store.memos.map(\.uid) == ["m1", "m2", "m3"], "the memo moved in the list")
        #expect(store.memos[1].attachments.map(\.uid) == ["a2"], "the wrong attachments went")
        #expect(store.memos[0].attachments.map(\.uid) == ["a0"])
        #expect(store.memos[2].attachments.map(\.uid) == ["a3"])
        #expect(store.lastError == nil)
    }

    /// A 404 is the same fact as a 204: the file is not on the server. It is what the web app
    /// having deleted it first looks like, and what a retry of a lost answer looks like.
    @Test("a 404 counts as gone, not as a failure")
    func the404CountsAsGone() async {
        let client = Stub.client { _, _, operation in
            operation == deleteAttachmentOperation
                ? Stub.empty(.notFound)
                : Self.page([Self.memo("m1", ["a1", "a2"])])
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client)

        #expect(removed)
        #expect(store.memos[0].attachments.map(\.uid) == ["a2"])
        #expect(store.lastError == nil, "a picture that is gone was reported as a failure")
    }

    @Test("a server error changes nothing and says so")
    func aServerErrorLeavesTheMemoAsItWas() async {
        let client = Stub.client { _, _, operation in
            operation == deleteAttachmentOperation
                ? Stub.empty(.internalServerError)
                : Self.page([Self.memo("m1", ["a1", "a2"])])
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client)

        #expect(!removed)
        #expect(
            store.memos[0].attachments.map(\.uid) == ["a1", "a2"],
            "a refused delete removed it"
        )
        #expect(store.lastError != nil, "a refused delete said nothing")
    }

    /// A store serializes its own mutations: a disabled button is never the guard. Two overlapping
    /// invocations for one uid are ONE request on the wire and both callers are told the same
    /// thing — the second joins the first rather than sending a sibling that would come back 404
    /// and be read as a fact about a file this app deleted itself.
    @Test("two deletes of one attachment are one request, with one answer")
    func twoDeletesOfOneAttachmentAreOneRequest() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let deletes = Counter()
        let client = Stub.client { _, _, operation in
            guard operation == deleteAttachmentOperation else {
                return Self.page([Self.memo("m1", ["a1", "a2"])])
            }
            deletes.increment()
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.empty(.noContent)
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)

        // Both are started before anything is awaited, so the second reaches the store while the
        // first is still on the wire — which is the interleaving the join exists for.
        let first = Task { await store.deleteAttachment(uid: "a1", from: "m1", using: client) }
        let second = Task { await store.deleteAttachment(uid: "a1", from: "m1", using: client) }
        while !entered.get() {
            await Task.yield()
        }
        release.set(true)
        let firstOutcome = await first.value
        let secondOutcome = await second.value

        #expect(firstOutcome)
        #expect(secondOutcome, "the joining caller was told something different")
        #expect(deletes.count == 1, "\(deletes.count) requests were sent for one attachment")
        #expect(store.memos[0].attachments.map(\.uid) == ["a2"])
    }

    /// The reconciling read: issued before the delete, answered after it, and still describing the
    /// memo as it was. It reaches the list through `apply`, so the tombstone is what stops it.
    @Test("a reconciling read that started before the delete cannot bring the picture back")
    func aReconcilingReadCannotBringItBack() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case deleteAttachmentOperation:
                return Stub.empty(.noContent)
            case getMemoOperation:
                entered.set(true)
                try await Self.hold(until: release)
                // The memo as it stood when this read went out: the picture is still on it.
                return Stub.json(Self.memo("m1", ["a1", "a2"]))
            default:
                return Self.page([Self.memo("m1", ["a1", "a2"])])
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let read = Task { await store.refreshMemo(uid: "m1", using: client, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client)
        release.set(true)
        let reached = await read.value

        #expect(removed)
        #expect(reached, "control: the read did reach the list")
        #expect(
            store.memos[0].attachments.map(\.uid) == ["a2"],
            "a stale read put the picture back"
        )
    }

    /// An edit's own answer is a whole memo from the server, landing through `patch` -> `apply`.
    /// The words it carries still arrive; the picture it also carries does not.
    @Test("an edit answered after the delete cannot bring the picture back")
    func anEditAnswerCannotBringItBack() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case deleteAttachmentOperation:
                return Stub.empty(.noContent)
            case patchMemoOperation:
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.json(
                    Stub.memo(
                        uid: "m1",
                        content: "after",
                        attachments: [
                            Stub.attachment(uid: "a1", status: "ready"),
                            Stub.attachment(uid: "a2", status: "ready"),
                        ]
                    )
                )
            default:
                return Self.page([Self.memo("m1", ["a1", "a2"])])
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let edit = Task {
            await store.edit(uid: "m1", content: "after", using: client, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client)
        release.set(true)
        let saved = await edit.value

        #expect(removed)
        #expect(saved)
        #expect(store.memos[0].content == "after", "control: the edit itself did not land")
        #expect(store.memos[0].attachments.map(\.uid) == ["a2"], "the edit put the picture back")
    }

    /// A page read before the delete carries the memo as it was. It is deliberately NOT fenced out
    /// — the delete leaves the list's lineage alone — so the tombstone is the only thing between it
    /// and a picture back on screen.
    @Test("a page answered after the delete cannot bring the picture back")
    func aPageCannotBringItBack() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let pages = Counter()
        let client = Stub.client { _, _, operation in
            guard operation == listMemosOperation else { return Stub.empty(.noContent) }
            pages.increment()
            guard pages.count > 1 else { return Self.page([Self.memo("m1", ["a1", "a2"])]) }
            entered.set(true)
            try await Self.hold(until: release)
            return Self.page([Self.memo("m1", ["a1", "a2"])])
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let page = Task { await store.refresh(using: client, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client)
        release.set(true)
        await page.value

        #expect(removed)
        #expect(pages.count == 2, "control: the second page really was read")
        #expect(store.memos.map(\.uid) == ["m1"], "control: the page landed")
        #expect(
            store.memos[0].attachments.map(\.uid) == ["a2"],
            "a stale page put the picture back"
        )
    }

    /// `fetchMemo` answers a caller with the memo as well as applying it, so BOTH copies have to be
    /// clean: a detail screen opened from the returned value would show a picture the list no
    /// longer has.
    @Test("a memo fetched after the delete carries the picture in neither copy")
    func aFetchedMemoCannotBringItBack() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case deleteAttachmentOperation:
                return Stub.empty(.noContent)
            case getMemoOperation:
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.json(Self.memo("m1", ["a1", "a2"]))
            default:
                return Self.page([Self.memo("m1", ["a1", "a2"])])
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let fetch = Task { await store.fetchMemo(uid: "m1", using: client, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client)
        release.set(true)
        let fetched = await fetch.value

        #expect(removed)
        #expect(fetched?.uid == "m1", "control: the fetch answered at all")
        #expect(
            fetched?.attachments.map(\.uid) == ["a2"],
            "the copy handed to the caller still had the picture on it"
        )
        #expect(store.memos[0].attachments.map(\.uid) == ["a2"])
    }

    /// The counter this delete deliberately does NOT fence on. `timelineGeneration` is the LIST's
    /// lineage, and a pull-to-refresh finishing mid-delete moves it — so a delete gated on it would
    /// throw away a 204 the server really sent.
    @Test("a refresh completing during the delete does not discard the answer")
    func aRefreshDuringTheDeleteDoesNotDiscardTheAnswer() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let pages = Counter()
        let client = Stub.client { _, _, operation in
            guard operation == deleteAttachmentOperation else {
                pages.increment()
                return Self.page([Self.memo("m1", ["a1", "a2"])])
            }
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.empty(.noContent)
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let deletion = Task { await store.deleteAttachment(uid: "a1", from: "m1", using: client) }
        while !entered.get() {
            await Task.yield()
        }
        // A whole refresh, start to finish, while the delete is on the wire: a new lineage, and a
        // page that still has the picture on it.
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(
            store.memos[0].attachments.map(\.uid) == ["a1", "a2"],
            "control: the refresh landed"
        )
        release.set(true)
        let removed = await deletion.value

        #expect(removed, "the 204 was thrown away because the list had moved on")
        #expect(pages.count == 2, "control: the refresh really was read")
        #expect(store.memos[0].attachments.map(\.uid) == ["a2"])
    }
}
