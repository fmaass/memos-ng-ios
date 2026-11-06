import Foundation
import MemosAPI
@testable import MemosCore
import Testing

/// The second phone needs no pull-to-refresh (MEMNG-966): the server's memo frames on
/// `/api/events` insert, patch and remove timeline rows where they sit.
///
/// The frames are the bytes memos-ng v2.14.0 writes (`app/routers/assets.sse_event`: an `event:`
/// name and `{uid, kind, guest}` as data), the reads go through the REAL generated client on a
/// scripted transport, and the stream is handed to `MediaChannel.consume` as values.
@MainActor
@Suite("Memo events")
struct MemoEventLiveTests {
    private nonisolated static let getMemo = "get_memo_api_memos__uid__get"
    private nonisolated static let listMemos = "list_memos_api_memos_get"

    // MARK: - decoding

    private nonisolated static func frame(_ type: String, _ data: String) -> ServerSentEvent {
        ServerSentEvent(type: type, data: data, lastEventID: "1-1")
    }

    @Test("each memo frame decodes by its event name, guest flag included")
    func memoFramesDecode() throws {
        #expect(
            try LiveEvent.decode(
                Self.frame("memo.created", #"{"uid": "m2", "kind": "created", "guest": null}"#))
                == .memo(MemoEvent(kind: .created, uid: "m2")))
        #expect(
            try LiveEvent.decode(
                Self.frame(
                    "memo.updated",
                    #"{"uid": "m2", "kind": "updated", "guest": {"contributor_name": "Ann", "pass_uid": "p1"}}"#
                )) == .memo(MemoEvent(kind: .updated, uid: "m2", isGuest: true)))
        #expect(
            try LiveEvent.decode(Self.frame("memo.deleted", #"{"uid": "m2", "kind": "deleted"}"#))
                == .memo(MemoEvent(kind: .deleted, uid: "m2")))
        #expect(
            try LiveEvent.decode(
                Self.frame(
                    "upload.progress",
                    #"{"upload_uid": "u1", "bytes_received": 4096, "declared_size": 10000}"#))
                == .uploadProgress(
                    UploadProgressEvent(uploadUID: "u1", bytesReceived: 4096, declaredSize: 10000)))
        #expect(throws: MediaEventDecodingError.unsupportedEventType("memo.visibility")) {
            try LiveEvent.decode(Self.frame("memo.visibility", #"{"uid": "m2"}"#))
        }
    }

    /// Pre-gate case, literal-in-string: the type is the frame's `event:` field, never a word in
    /// its data.
    @Test("a frame's type comes from its event name, never from words in its data")
    func typeIsTheEventNameNotTheData() throws {
        #expect(
            try LiveEvent.decode(Self.frame("memo.deleted", #"{"uid": "m2", "kind": "created"}"#))
                == .memo(MemoEvent(kind: .deleted, uid: "m2")))
        guard
            case .media(let media) = try LiveEvent.decode(
                Self.frame("message", #"{"uid": "memo.created", "status": "ready"}"#))
        else {
            Issue.record("a media frame naming memo.created in its data was not read as media")
            return
        }
        #expect(media.uid == "memo.created")
    }

    // MARK: - fixtures

    private struct Fixture {
        let store: TimelineStore
        let client: any APIProtocol
        let gets: Counter
    }

    /// A store loaded with `rows` (one page, no more), whose single-memo reads answer `reads[uid]`.
    private func loaded(
        _ rows: [String],
        reads: [String: String] = [:],
        query: MemoQuery = .empty,
        before: Gate? = nil,
        reached: Gate? = nil,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) async -> Fixture {
        let gets = Counter()
        let client = Stub.client { request, _, operation in
            switch operation {
            case Self.listMemos:
                return Stub.json(Stub.page(rows))
            case Self.getMemo:
                gets.increment()
                reached?.open()
                await before?.wait()
                let uid = request.path?.split(separator: "/").last.map(String.init) ?? ""
                guard let body = reads[uid] else { return Stub.empty(.notFound) }
                if body == "401" { return Stub.empty(.unauthorized) }
                return Stub.json(body)
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = TimelineStore(query: query, onUnauthorized: onUnauthorized)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        return Fixture(store: store, client: client, gets: gets)
    }

    private func consume(
        _ events: [MemoEvent],
        _ fixture: Fixture,
        identity: MediaIdentity,
        generation: Int? = nil
    ) async {
        let stamp = generation ?? identity.generation
        await MediaChannel.consume(
            AsyncStream { continuation in
                for event in events {
                    continuation.yield(.memo(MemoEventEnvelope(event: event, generation: stamp)))
                }
                continuation.finish()
            },
            into: fixture.store,
            using: fixture.client.handle,
            baseURL: Stub.baseURL,
            identity: identity
        )
    }

    private func uids(_ store: TimelineStore) -> [String] { store.memos.map(\.uid) }

    // MARK: - acceptance

    @Test("a memo.updated while the edit sheet is open updates the card and leaves the draft")
    func anUpdateUnderAnOpenEditorPatchesOnlyTheCard() async {
        let fixture = await loaded(
            [Stub.memo(uid: "m1", content: "before")],
            reads: [
                "m1": Stub.memo(
                    uid: "m1", content: "changed on the other phone",
                    updatedAt: "2026-08-23T10:00:00Z")
            ]
        )
        // What the edit sheet opens on (`TimelineView.editMode(for:)` takes this value): the
        // memo as it stood, copied out of the list.
        let draft = fixture.store.memos[0]

        await consume([MemoEvent(kind: .updated, uid: "m1")], fixture, identity: MediaIdentity())

        #expect(fixture.gets.count == 1)
        #expect(fixture.store.memos.first?.content == "changed on the other phone")
        #expect(draft.content == "before", "the editor's copy was written to")
    }

    @Test("a memo frame stamped for a generation the device has left is dropped")
    func aStaleGenerationMemoFrameIsDropped() async {
        let fixture = await loaded(
            [Stub.memo(uid: "m1")],
            reads: ["m2": Stub.memo(uid: "m2", createdAt: "2026-08-24T09:00:00Z")]
        )
        let identity = MediaIdentity()
        let stamped = identity.generation
        identity.rotate()

        await consume(
            [MemoEvent(kind: .created, uid: "m2"), MemoEvent(kind: .deleted, uid: "m1")],
            fixture, identity: identity, generation: stamped)

        #expect(fixture.gets.count == 0, "a frame from the previous account issued a read")
        #expect(uids(fixture.store) == ["m1"])

        // Control: the same frames under a clock that did not move DO apply.
        await consume(
            [MemoEvent(kind: .created, uid: "m2"), MemoEvent(kind: .deleted, uid: "m1")],
            fixture, identity: MediaIdentity(), generation: 0)
        #expect(uids(fixture.store) == ["m2"])
    }

    @Test("a memo.created the query would show is inserted in order")
    func aCreatedMemoIsInsertedInOrder() async {
        let fixture = await loaded(
            [
                Stub.memo(uid: "m3", createdAt: "2026-08-25T09:00:00Z"),
                Stub.memo(uid: "m1", createdAt: "2026-08-23T09:00:00Z"),
            ],
            reads: ["m2": Stub.memo(uid: "m2", createdAt: "2026-08-24T09:00:00Z")]
        )

        await consume([MemoEvent(kind: .created, uid: "m2")], fixture, identity: MediaIdentity())

        #expect(uids(fixture.store) == ["m3", "m2", "m1"])
    }

    @Test("a memo.deleted removes the card")
    func aDeletedMemoLeaves() async {
        let fixture = await loaded([Stub.memo(uid: "m1"), Stub.memo(uid: "m2")])

        await consume([MemoEvent(kind: .deleted, uid: "m1")], fixture, identity: MediaIdentity())

        #expect(uids(fixture.store) == ["m2"])
        #expect(fixture.gets.count == 0)
    }

    /// The server has no visibility frame: a memo made private reaches the household as
    /// `memo.deleted`, and its owner — who still sees it — as `memo.updated`.
    @Test("a visibility change drops the memo for the household and re-reads it for its owner")
    func aVisibilityChangeApplies() async {
        let household = await loaded([
            Stub.memo(uid: "m1", visibility: "PROTECTED"), Stub.memo(uid: "m2"),
        ])
        await consume([MemoEvent(kind: .deleted, uid: "m1")], household, identity: MediaIdentity())
        #expect(uids(household.store) == ["m2"], "a memo this person can no longer see stayed")

        let owner = await loaded(
            [Stub.memo(uid: "m1", visibility: "PROTECTED")],
            reads: [
                "m1": Stub.memo(
                    uid: "m1", visibility: "PRIVATE", updatedAt: "2026-08-23T10:00:00Z")
            ]
        )
        await consume([MemoEvent(kind: .updated, uid: "m1")], owner, identity: MediaIdentity())
        #expect(owner.store.memos.first?.visibility == .private)
    }

    // MARK: - pre-gate cases

    /// Scope label: the home timeline excludes guest memos (MEMNG-1164); a trip's list asks for them.
    @Test("a guest memo's created frame reaches a trip's list and never the home timeline")
    func guestMemosStayOutOfTheHomeTimeline() async {
        let read = ["g1": Stub.memo(uid: "g1", createdAt: "2026-08-24T09:00:00Z")]
        let guest = MemoEvent(kind: .created, uid: "g1", isGuest: true)

        let home = await loaded([Stub.memo(uid: "m1")], reads: read)
        await consume([guest], home, identity: MediaIdentity())
        #expect(uids(home.store) == ["m1"])
        #expect(home.gets.count == 0, "the home timeline read a guest memo it must not show")

        let trip = await loaded(
            [Stub.memo(uid: "m1")], reads: read, query: MemoQuery(includeGuests: true))
        await consume([guest], trip, identity: MediaIdentity())
        #expect(uids(trip.store) == ["g1", "m1"])
    }

    /// Boundary: an empty window, both edges, and the middle.
    @Test("a created memo lands inside the loaded window or not at all")
    func theWindowDecidesWhereACreatedMemoGoes() {
        func memo(_ uid: String, _ day: Int) -> Memo {
            Memo(
                uid: uid, owner: "fabian", mine: true, content: "", visibility: .private,
                pinned: false, createdAt: Date(timeIntervalSince1970: Double(day) * 86_400),
                updatedAt: Date(timeIntervalSince1970: 0))
        }
        let window = [memo("c", 30), memo("a", 10)]
        let index = { (new: Memo, list: [Memo], newer: Bool, more: Bool) in
            TimelineStore.liveInsertionIndex(for: new, in: list, hasNewer: newer, hasMore: more)
        }
        #expect(index(memo("n", 20), [], false, true) == nil, "an unread list took a row")
        #expect(index(memo("n", 20), [], false, false) == 0)
        #expect(index(memo("n", 20), window, true, true) == 1)
        #expect(index(memo("n", 40), window, false, true) == 0)
        #expect(index(memo("n", 40), window, true, false) == nil, "landed above unread newer pages")
        #expect(index(memo("n", 5), window, false, false) == 2)
        #expect(index(memo("n", 5), window, false, true) == nil, "landed above unread older pages")
    }

    /// Error path: a refusal of the insert's read reaches the session's refusal funnel and inserts
    /// nothing; it is not swallowed as "no such memo".
    @Test("a 401 on a created memo's read reaches the refusal funnel and inserts nothing")
    func aRefusedInsertReadIsReported() async {
        let refused = Counter()
        let fixture = await loaded(
            [Stub.memo(uid: "m1")], reads: ["m2": "401"],
            onUnauthorized: { _ in
                refused.increment()
                return .endedSession
            })

        await consume([MemoEvent(kind: .created, uid: "m2")], fixture, identity: MediaIdentity())

        #expect(refused.count == 1)
        #expect(uids(fixture.store) == ["m1"])
    }

    /// Concurrency: two frames for one created memo are ONE read (joined), and a delete that lands
    /// while that read is in the air is not undone by its answer.
    @Test("two created frames are one read, and a delete during it is not resurrected")
    func overlappingFramesAreSerialized() async {
        let before = Gate()
        let reached = Gate()
        let fixture = await loaded(
            [Stub.memo(uid: "m1")],
            reads: ["m2": Stub.memo(uid: "m2", createdAt: "2026-08-24T09:00:00Z")],
            before: before, reached: reached)
        let store = fixture.store
        let handle = fixture.client.handle
        let created = MemoEvent(kind: .created, uid: "m2")

        // The first frame's read is in the air and HELD at the transport.
        let first = Task { await store.apply(created, using: handle, baseURL: Stub.baseURL) }
        await reached.wait()
        // The second frame arrives while it is held. Both tasks are main-actor tasks, enqueued in
        // order, so once a task enqueued AFTER the second has run, the second has run up to its
        // own first suspension — the join, or a second request.
        let second = Task { await store.apply(created, using: handle, baseURL: Stub.baseURL) }
        await Task {}.value
        #expect(fixture.gets.count == 1, "the second frame issued its own read instead of joining")
        await store.apply(
            MemoEvent(kind: .deleted, uid: "m2"), using: handle, baseURL: Stub.baseURL)
        before.open()
        await first.value
        await second.value

        #expect(fixture.gets.count == 1, "two created frames for one memo were two reads")
        #expect(uids(store) == ["m1"], "a removed memo came back on a read that predated it")
    }
}
