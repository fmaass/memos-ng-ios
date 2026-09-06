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

    /// The calendar an anchor is read in, and a day to anchor on — an anchored list is the only
    /// kind that believes there is anything above it, so it is the only one that pages upward.
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private static let anchored = MemoQuery(anchor: .day(year: 2026, month: 8, day: 24))

    /// F3. `deleteAttachment` claims its slot and then does the work in a Task of its own, so the
    /// session can be withdrawn between the handle being captured and that body starting. Only the
    /// ANSWER was fenced, and for a DELETE that is the wrong half: discarding a 204 afterwards does
    /// not put the file back on the server. Every sibling write in this store asks synchronously
    /// before it sends; this one now does too.
    @Test("a delete whose session was withdrawn before its task ran sends nothing")
    func aDeleteForAWithdrawnSessionIsNeverSent() async throws {
        let sends = LockedValue<Int>(0)
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, operation in
                    guard operation != "whoami_api_auth_user_get" else {
                        return Stub.json(Stub.user)
                    }
                    guard operation == deleteAttachmentOperation else {
                        return Self.page([Self.memo("m1", ["a1", "a2"])])
                    }
                    sends.set(sends.get() + 1)
                    return Stub.empty(.noContent)
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        let store = TimelineStore()
        store.reports(to: session)
        let handle = try #require(session.activeHandle)
        await store.refresh(using: handle, baseURL: Stub.baseURL)
        #expect(store.memos.first?.attachments.count == 2, "control: the list landed")

        // Withdrawn AFTER the handle was taken and BEFORE the delete is asked for — the window the
        // task's own scheduling opens.
        await session.signOutWithoutRevoking()
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: handle)

        #expect(!removed)
        #expect(sends.get() == 0, "a DELETE went out for a session this device had left")
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client.handle)

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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let removed = await store.deleteAttachment(uid: "a1", from: "m2", using: client.handle)

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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client.handle)

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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client.handle)

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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        // Both are started before anything is awaited, so the second reaches the store while the
        // first is still on the wire — which is the interleaving the join exists for.
        let handle = client.handle
        let first = Task { await store.deleteAttachment(uid: "a1", from: "m1", using: handle) }
        let second = Task { await store.deleteAttachment(uid: "a1", from: "m1", using: handle) }
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let handle = client.handle
        let read = Task {
            await store.refreshMemo(uid: "m1", using: handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client.handle)
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let edit = Task {
            await store.edit(
                uid: "m1",
                content: "after",
                using: client.handle,
                baseURL: Stub.baseURL
            )
        }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client.handle)
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let page = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client.handle)
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let handle = client.handle
        let fetch = Task {
            await store.fetchMemo(uid: "m1", using: handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client.handle)
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

    /// The optimistic write's ROLLBACK, which restores a snapshot taken before the request.
    ///
    /// `toggleTask` is the one write in this store that moves the list before the server answers,
    /// so it is the one that holds a pre-request copy of a memo — and a failed patch puts that copy
    /// back. The copy was taken before the delete, so a raw restore is a resurrection by the one
    /// door that never goes near a server answer.
    @Test("a failed checkbox rolls the tick back without rolling the picture back")
    func aFailedToggleDoesNotRestoreADeletedPicture() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            switch operation {
            case deleteAttachmentOperation:
                return Stub.empty(.noContent)
            case patchMemoOperation:
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.empty(.internalServerError)
            default:
                return Stub.json(
                    Stub.page([
                        Stub.memo(
                            uid: "m1",
                            content: "- [ ] ring the plumber",
                            attachments: [
                                Stub.attachment(uid: "a1", status: "ready"),
                                Stub.attachment(uid: "a2", status: "ready"),
                            ]
                        )
                    ])
                )
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let tick = Task {
            await store.toggleTask(at: 0, in: "m1", using: client.handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client.handle)
        release.set(true)
        let ticked = await tick.value

        #expect(removed)
        #expect(!ticked, "control: the patch was refused, so there is a rollback to judge")
        // The tick goes back, which is what the snapshot is for.
        #expect(store.memos[0].content == "- [ ] ring the plumber", "the tick did not roll back")
        // The picture does not, which is what the snapshot must not be allowed to do.
        #expect(
            store.memos[0].attachments.map(\.uid) == ["a2"],
            "a failed checkbox put a deleted picture back"
        )
    }

    /// The rule stated as a REQUEST COUNT, so it fails if anyone ever fences this delete on the
    /// list's lineage. A next page issued before the delete and answered after it is a
    /// continuation of a list the delete did not change — it lands, once, minus the picture. A
    /// generation bump would have `loadMore` drop it and ask again, which is the second request
    /// this counts.
    @Test("a page in flight when the delete lands still lands, and is not asked for twice")
    func aPageInFlightStillLands() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let secondPages = Counter()
        let client = Stub.client { request, _, operation in
            guard operation == listMemosOperation else { return Stub.empty(.noContent) }
            guard request.path?.contains("cursor=page-2") == true else {
                return Stub.json(
                    Stub.page([Self.memo("m1", ["x1"])], nextCursor: "page-2")
                )
            }
            secondPages.increment()
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.json(Stub.page([Self.memo("m2", ["a1", "a2"])]))
        }
        let store = TimelineStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.hasMore)

        let page = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        // The memo this attachment is on is not loaded yet; the delete is still a fact about it.
        let removed = await store.deleteAttachment(uid: "a1", from: "m2", using: client.handle)
        release.set(true)
        await page.value

        #expect(removed)
        #expect(store.memos.map(\.uid) == ["m1", "m2"], "the page in flight was dropped")
        #expect(!store.hasMore, "the page's own cursor was not adopted")
        #expect(secondPages.count == 1, "the page was asked for \(secondPages.count) times")
        #expect(
            store.memos[1].attachments.map(\.uid) == ["a2"],
            "the page brought the picture back"
        )
    }

    /// The block ABOVE an anchored list, which is its own admission lane.
    @Test("a page above answered after the delete cannot bring the picture back")
    func anUpwardPageCannotBringItBack() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { request, _, operation in
            guard operation == listMemosOperation else { return Stub.empty(.noContent) }
            guard request.path?.contains("sort=created_at") == true else {
                return Stub.json(
                    Stub.page(
                        [Stub.memo(uid: "m1", createdAt: "2026-08-24T18:00:00Z")],
                        nextCursor: nil
                    )
                )
            }
            entered.set(true)
            try await Self.hold(until: release)
            // Ascending, the memos directly above the list — one of them carrying the picture.
            return Stub.json(
                Stub.page([
                    Stub.memo(
                        uid: "m2",
                        createdAt: "2026-08-25T09:00:00Z",
                        attachments: [
                            Stub.attachment(uid: "a1", status: "ready"),
                            Stub.attachment(uid: "a2", status: "ready"),
                        ]
                    )
                ])
            )
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.hasNewer, "control: an anchored list has something above it")

        let above = Task { await store.loadNewer(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.deleteAttachment(uid: "a1", from: "m2", using: client.handle)
        release.set(true)
        _ = await above.value

        #expect(removed)
        #expect(store.memos.map(\.uid) == ["m2", "m1"], "control: the block above landed on top")
        #expect(
            store.memos[0].attachments.map(\.uid) == ["a2"],
            "the page above brought the picture back"
        )
    }

    /// A created memo is a server memo too, and it goes in by its own door (`placed`) rather than
    /// through `apply`. Nothing realistic puts a deleted uid on a memo made afterwards — the point
    /// is that the lane is covered rather than trusted.
    @Test("a created memo cannot arrive carrying a picture this session deleted")
    func aCreatedMemoCannotBringItBack() async {
        let client = Stub.client { _, _, operation in
            switch operation {
            case deleteAttachmentOperation:
                return Stub.empty(.noContent)
            case "create_memo_api_memos_post":
                return Stub.json(
                    Stub.memo(
                        uid: "m2",
                        content: "new",
                        createdAt: "2026-08-25T09:00:00Z",
                        attachments: [
                            Stub.attachment(uid: "a1", status: "ready"),
                            Stub.attachment(uid: "a2", status: "ready"),
                        ]
                    ),
                    status: .created
                )
            default:
                return Self.page([Self.memo("m1", ["a1"])])
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let removed = await store.deleteAttachment(uid: "a1", from: "m1", using: client.handle)
        #expect(removed)

        let created = await store.create(
            content: "new",
            using: client.handle,
            baseURL: Stub.baseURL
        )

        #expect(created)
        #expect(store.memos.map(\.uid) == ["m2", "m1"], "control: the created memo was placed")
        #expect(
            store.memos[0].attachments.map(\.uid) == ["a2"],
            "a created memo brought a deleted picture back"
        )
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let handle = client.handle
        let deletion = Task {
            await store.deleteAttachment(uid: "a1", from: "m1", using: handle)
        }
        while !entered.get() {
            await Task.yield()
        }
        // A whole refresh, start to finish, while the delete is on the wire: a new lineage, and a
        // page that still has the picture on it.
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
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
