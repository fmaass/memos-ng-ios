import Foundation
import MemosAPI
import MemosCore
import Testing

/// The reconciling read and one live event, at every ordering the two can arrive in.
///
/// `TimelineStore.refreshMemo` reads a memo the list already holds and merges the answer around
/// whatever the stream said while it was in the air. That merge is keyed per ATTACHMENT, on
/// `liveApplications` — a count of the events this list has APPLIED to each one — and the count is
/// only bumped when the event actually MOVED the list. Which is the whole of the question below:
/// an event about an attachment the loaded row does not hold yet moves nothing, so it leaves no
/// mark, and the read that is about to INTRODUCE that attachment has nothing to merge against.
///
/// The matrix, as of MEMNG-197 — rows are what the event names, columns are when it lands relative
/// to the answer of the read it raced:
///
///     event names an attachment…       | lands BEFORE the answer      | lands AFTER the answer
///     ---------------------------------|------------------------------|------------------------
///     in the loaded row AND the answer  | covered: the event moves the | covered: the answer is
///                                       | list, `liveApplications`     | already in the list, so
///                                       | bumps, and `reconciled`      | the event is an ordinary
///                                       | keeps the moved attachment   | apply — nothing to fence
///     in the ANSWER only (absent from   | WAS LOST: nothing moved, so  | covered: the answer put
///     the loaded row)                   | nothing was remembered, and  | the attachment in the row
///                                       | the answer's snapshot state  | first, so the event finds
///                                       | won — this is the ticket     | it and moves it
///     in NEITHER                        | nothing is owed: no row      | nothing is owed: the
///                                       | holds it and the answer does | answer did not introduce
///                                       | not introduce it             | it either
///
/// One test per cell, each with the GET parked at the scripted server so the ordering is stated
/// rather than raced for, plus the two fences the retain-replay needs: what a read kept is spent
/// on that read's own answer and on nothing later, whether that read succeeded or failed.
///
/// Nothing here waits on a clock. The requests go through a REAL generated client on a scripted
/// transport, and the events are the ones a real memos-ng wrote (`SSEFixture`).
@MainActor
@Suite("Reconcile racing a live event")
struct TimelineReconcileRaceTests {
    private nonisolated static let uid = "m1"
    /// The attachment the loaded row has held since it was read.
    private nonisolated static let held = "e5f6a7b8"
    /// The attachment only the reconciling read brings in — the one that finished before the
    /// connection took its snapshot, which is the entire reason that read exists.
    private nonisolated static let introduced = "a1b2c3d4"

    /// The worker's finish on each, from the captured frames.
    private nonisolated static var heldReady: MediaEvent { SSEFixture.liveEvents[4] }
    private nonisolated static var introducedReady: MediaEvent { SSEFixture.liveEvents[2] }

    private nonisolated static func memo(_ attachments: [(uid: String, status: String)]) -> String {
        Stub.memo(
            uid: uid,
            attachments: attachments.map { Stub.attachment(uid: $0.uid, status: $0.status) }
        )
    }

    /// Keeps a scripted request open until the test lets it go. `nonisolated`, because the
    /// transport runs off the main actor.
    private nonisolated static func hold(until release: LockedValue<Bool>) async throws {
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private struct Parked {
        let store: TimelineStore
        let client: any APIProtocol
        /// A reconciling read has reached the server and is being held there.
        let entered: LockedValue<Bool>
        /// Let the held read answer.
        let release: LockedValue<Bool>
        let reads: Counter
    }

    /// A timeline with one row in it, and a reconciling GET scripted to park at the server until
    /// the test lets it answer.
    ///
    /// - Parameter answers: what each successive read answers, in order; `nil` is a read that
    ///   fails, which is one of the two ways a kept event has to be let go of.
    private func parked(loaded: String, answering answers: [String?]) async -> Parked {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let reads = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([loaded]))
            case "get_memo_api_memos__uid__get":
                let index = min(reads.count, answers.count - 1)
                reads.increment()
                entered.set(true)
                try await Self.hold(until: release)
                guard let answer = answers[index] else { return Stub.empty(.internalServerError) }
                return Stub.json(answer)
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        return Parked(
            store: store,
            client: client,
            entered: entered,
            release: release,
            reads: reads
        )
    }

    /// Issues one reconciling read, delivers the event while that read is parked at the server,
    /// and only then lets the answer land. The parking IS the test: without it the event would
    /// meet whichever list the scheduler happened to leave behind.
    @discardableResult
    private func read(
        _ fixture: Parked,
        deliveringWhileParked event: MediaEvent? = nil
    ) async -> Bool {
        fixture.entered.set(false)
        fixture.release.set(false)
        let reading = Task {
            await fixture.store.refreshMemo(
                uid: Self.uid, using: fixture.client.handle, baseURL: Stub.baseURL
            )
        }
        while !fixture.entered.get() {
            await Task.yield()
        }
        if let event { await fixture.store.apply(event) }
        fixture.release.set(true)
        return await reading.value
    }

    private func attachment(_ uid: String, in store: TimelineStore) -> MemoAttachment? {
        store.memos.first { $0.uid == Self.uid }?.attachments.first { $0.uid == uid }
    }

    // MARK: - the attachment is in the loaded row AND in the answer

    /// The cell the per-attachment merge was written for: the read describes the attachment as it
    /// was when the request went out, the event describes it as it is now, and the event wins.
    @Test("an event for an attachment the row already holds survives the answer that raced it")
    func inRowAndAnswerBeforeTheAnswer() async {
        let fixture = await parked(
            loaded: Self.memo([(Self.held, "pending")]),
            answering: [Self.memo([(Self.held, "pending")])]
        )
        #expect(
            attachment(Self.held, in: fixture.store)?.readiness == .waiting,
            "the row did not load waiting, so the event below proves nothing"
        )

        let landed = await read(fixture, deliveringWhileParked: Self.heldReady)

        #expect(landed)
        #expect(
            attachment(Self.held, in: fixture.store)?.readiness == .ready,
            "the answer's older snapshot put a finished tile back under the waiting treatment"
        )
    }

    /// The same two facts in the other order, which needs no fence at all: by the time the event
    /// arrives the answer is in the list, so it is an ordinary apply.
    @Test("an event for an attachment the row holds moves it after the answer has landed")
    func inRowAndAnswerAfterTheAnswer() async {
        let fixture = await parked(
            loaded: Self.memo([(Self.held, "pending")]),
            answering: [Self.memo([(Self.held, "pending")])]
        )

        let landed = await read(fixture)

        #expect(landed)
        #expect(
            attachment(Self.held, in: fixture.store)?.readiness == .waiting,
            "the answer landed finished, so the event below proves nothing"
        )
        await fixture.store.apply(Self.heldReady)
        #expect(attachment(Self.held, in: fixture.store)?.readiness == .ready)
    }

    // MARK: - the attachment is in the ANSWER only (MEMNG-197)

    /// The cell this ticket is about.
    ///
    /// The reconciling read is the read that INTRODUCES the attachment: it is not in the loaded
    /// row, because it finished before this connection took its snapshot — the one case the stream
    /// cannot report, and the reason the read is taken. The terminal event for that same
    /// attachment then lands while the read is in the air. It moves nothing, because no row holds
    /// the attachment yet, so it leaves no mark in `liveApplications` and is consumed without
    /// trace; the answer then introduces the attachment in the state the server was in when the
    /// request went out. Nothing repeats the event: the stream synthesises `ready` ONCE, from a uid
    /// dropping out of the connection's snapshot, and that has already happened.
    @Test("a terminal event racing the read that introduces its attachment survives it")
    func inAnswerOnlyBeforeTheAnswer() async {
        let fixture = await parked(
            loaded: Self.memo([(Self.held, "ready")]),
            answering: [Self.memo([(Self.held, "ready"), (Self.introduced, "pending")])]
        )
        #expect(
            attachment(Self.introduced, in: fixture.store) == nil,
            "the row already held the attachment the read is supposed to introduce"
        )

        let landed = await read(fixture, deliveringWhileParked: Self.introducedReady)

        #expect(landed)
        let tile = attachment(Self.introduced, in: fixture.store)
        #expect(tile != nil, "the answer did not introduce the attachment at all")
        #expect(
            tile?.readiness == .ready,
            "the event that raced the read introducing its attachment was consumed without trace"
        )
        // And with the layout the worker wrote, which is the other half of what that event
        // carried and the only place the tile's aspect ratio can come from.
        #expect(tile?.width == 4032, "the introduced tile kept the answer's placeholder layout")
        #expect(tile?.height == 3024)
        #expect(tile?.blurhash == "LEHV6nWB2yk8pyo0adR*.7kCMdnj")

        // Control, in the same run: the same event on the same store, now that the row holds the
        // attachment, does move it — so a failure above is about the race and not a dead event.
        await fixture.store.apply(Self.introducedReady)
        #expect(attachment(Self.introduced, in: fixture.store)?.readiness == .ready)
    }

    /// The same two facts in the other order: the answer introduces the attachment first, so the
    /// event finds a row to move.
    @Test("an event for an attachment the answer introduced moves it once the answer has landed")
    func inAnswerOnlyAfterTheAnswer() async {
        let fixture = await parked(
            loaded: Self.memo([(Self.held, "ready")]),
            answering: [Self.memo([(Self.held, "ready"), (Self.introduced, "pending")])]
        )

        let landed = await read(fixture)

        #expect(landed)
        #expect(
            attachment(Self.introduced, in: fixture.store)?.readiness == .waiting,
            "the answer introduced it already finished, so the event below proves nothing"
        )
        await fixture.store.apply(Self.introducedReady)
        let tile = attachment(Self.introduced, in: fixture.store)
        #expect(tile?.readiness == .ready)
        #expect(tile?.width == 4032)
        #expect(tile?.height == 3024)
    }

    // MARK: - the attachment is in NEITHER

    /// An event about a file this list has nothing to do with — somebody else's upload, or a memo
    /// a hundred cursor pages down. Nothing is owed for it, and nothing it leaves behind may
    /// colour the answer of the read it happened to arrive during.
    @Test("an event for an attachment neither the row nor the answer holds changes nothing")
    func inNeitherBeforeTheAnswer() async {
        let fixture = await parked(
            loaded: Self.memo([(Self.held, "pending")]),
            answering: [Self.memo([(Self.held, "pending")])]
        )

        let landed = await read(fixture, deliveringWhileParked: Self.introducedReady)

        #expect(landed)
        #expect(
            fixture.store.memos.first?.attachments.map(\.uid) == [Self.held],
            "an event for an attachment nothing holds put one into the list"
        )
        #expect(
            attachment(Self.held, in: fixture.store)?.readiness == .waiting,
            "an event for another attachment entirely moved this one"
        )

        // Control: the event this list DOES hold an attachment for moves it, on the same store.
        await fixture.store.apply(Self.heldReady)
        #expect(attachment(Self.held, in: fixture.store)?.readiness == .ready)
    }

    @Test("an event for an attachment nothing holds changes nothing after the answer either")
    func inNeitherAfterTheAnswer() async {
        let fixture = await parked(
            loaded: Self.memo([(Self.held, "pending")]),
            answering: [Self.memo([(Self.held, "pending")])]
        )

        let landed = await read(fixture)
        #expect(landed)
        let before = fixture.store.memos

        await fixture.store.apply(Self.introducedReady)

        #expect(
            fixture.store.memos == before,
            "an event for an attachment nothing holds moved the list"
        )
    }

    // MARK: - what a read keeps, it keeps for its OWN answer

    /// An event kept against a read in flight is spent on the answer of THAT read.
    ///
    /// The fence is the same one every read in this store carries: a response is judged against
    /// the generation that ISSUED its request, never the list as it stands when it lands. So the
    /// first read — which the event raced and whose answer did not introduce the attachment —
    /// takes what it kept with it, and the second read, which no event went anywhere near, gets
    /// the server's own word and nothing else.
    @Test("an event kept for one read is not replayed into the next one")
    func aKeptEventIsSpentOnItsOwnRead() async {
        let fixture = await parked(
            loaded: Self.memo([(Self.held, "ready")]),
            answering: [
                Self.memo([(Self.held, "ready")]),
                Self.memo([(Self.held, "ready"), (Self.introduced, "pending")]),
            ]
        )

        let raced = await read(fixture, deliveringWhileParked: Self.introducedReady)
        #expect(raced)
        #expect(
            attachment(Self.introduced, in: fixture.store) == nil,
            "the first answer introduced the attachment, so the second read proves nothing"
        )

        let next = await read(fixture)
        #expect(next)

        let tile = attachment(Self.introduced, in: fixture.store)
        #expect(tile != nil, "the second answer did not introduce the attachment")
        #expect(
            tile?.readiness == .waiting,
            "an event kept for a read that has already answered coloured a later one"
        )
        #expect(fixture.reads.count == 2)
    }

    /// The other way a read ends. A failed read hands nothing to the list, and what it was keeping
    /// goes with it rather than waiting for whatever asks next.
    @Test("an event kept for a read that failed is dropped with it")
    func aKeptEventDiesWithAFailedRead() async {
        let fixture = await parked(
            loaded: Self.memo([(Self.held, "ready")]),
            answering: [
                nil,
                Self.memo([(Self.held, "ready"), (Self.introduced, "pending")]),
            ]
        )

        let failed = await read(fixture, deliveringWhileParked: Self.introducedReady)
        #expect(!failed, "the scripted failure answered anyway, so this proves nothing")

        let next = await read(fixture)
        #expect(next)

        let tile = attachment(Self.introduced, in: fixture.store)
        #expect(tile != nil, "the second answer did not introduce the attachment")
        #expect(
            tile?.readiness == .waiting,
            "an event kept for a read that failed was replayed into the next one"
        )
    }
}
