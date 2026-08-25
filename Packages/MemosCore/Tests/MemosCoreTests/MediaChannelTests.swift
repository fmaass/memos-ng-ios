import Foundation
import MemosAPI
@testable import MemosCore
import Observation
import Testing

/// The waiting has to END without anybody doing anything.
///
/// A memo is created before its pictures are derived, so a freshly posted one arrives with
/// attachments the server has not finished with, and those tiles show a waiting treatment. What
/// takes it off again is this: the server pushes an event as each attachment is derived, and the
/// tile flips where it sits.
///
/// Nothing here waits on a clock or a connection. The stream is handed over as values, the identity
/// clock is a local instance moved by hand, and the requests the reconciling pass makes are counted
/// through a REAL generated client on a scripted transport.
@MainActor
@Suite("Media channel")
struct MediaChannelTests {
    /// The uid the captured server frames are about (`SSEFixture`), so the events these tests apply
    /// are the ones a real memos-ng wrote rather than ones invented to match the assertion.
    private nonisolated static let attachment = "a1b2c3d4"
    private nonisolated static let uid = "m1"

    private nonisolated static func memo(
        _ status: String,
        uid: String = MediaChannelTests.uid,
        attachment: String = MediaChannelTests.attachment
    ) -> String {
        Stub.memo(uid: uid, attachments: [Stub.attachment(uid: attachment, status: status)])
    }

    /// A store holding one memo whose single attachment is at the given stage, loaded the way the
    /// app loads one — and the client it was loaded through, because `consume` reconciles at every
    /// connection open and a fixture that opens one really does re-read.
    ///
    /// The re-read answers with the SAME stage by default, so it is a no-op: a test about what an
    /// EVENT does must not be able to pass on what the reconcile fetched instead.
    private struct Loaded {
        let store: TimelineStore
        let client: any APIProtocol
        let gets: Counter
    }

    private func loaded(_ status: String, reReadsAs: String? = nil) async -> Loaded {
        let gets = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Self.memo(status)]))
            case "get_memo_api_memos__uid__get":
                gets.increment()
                return Stub.json(Self.memo(reReadsAs ?? status))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)
        return Loaded(store: store, client: client, gets: gets)
    }

    /// `consume`, wired to the stub the store was loaded through.
    private func consume(
        _ items: [MediaEventStreamItem],
        _ fixture: Loaded,
        identity: MediaIdentity
    ) async {
        await MediaChannel.consume(
            channel(items),
            into: fixture.store,
            using: fixture.client,
            baseURL: Stub.baseURL,
            identity: identity
        )
    }

    /// A finite channel of exactly these items, already buffered. That is not a shortcut: an event
    /// really does sit in the stream's buffer between arriving and being consumed, which is the
    /// window the generation stamp exists to close.
    private func channel(
        _ items: [MediaEventStreamItem]
    ) -> AsyncStream<MediaEventStreamItem> {
        AsyncStream { continuation in
            for item in items { continuation.yield(item) }
            continuation.finish()
        }
    }

    private func envelope(
        _ event: MediaEvent,
        generation: Int = 0
    ) -> MediaEventEnvelope {
        MediaEventEnvelope(event: event, generation: generation)
    }

    /// The event the worker's finish produces, decoded from the bytes memos-ng actually writes.
    private nonisolated static var readyEvent: MediaEvent { SSEFixture.liveEvents[2] }
    /// The same attachment, mid-transcode.
    private nonisolated static var processingEvent: MediaEvent { SSEFixture.liveEvents[1] }

    // MARK: - the whole point

    @Test("a waiting tile goes ready on its event, carrying the layout the worker wrote")
    func aWaitingTileGoesReadyOnItsEvent() async {
        let fixture = await loaded("pending")
        let store = fixture.store
        let identity = MediaIdentity()
        #expect(store.memos.first?.attachments.first?.readiness == .waiting)
        #expect(store.memos.first?.isAwaitingTiers == true)

        await consume(
            [.state(.open), .event(envelope(Self.readyEvent))],
            fixture,
            identity: identity
        )

        // The open's reconcile re-read it as PENDING, so `ready` below can only have come from the
        // event.
        #expect(fixture.gets.count == 1)
        let patched = store.memos.first?.attachments.first
        #expect(patched?.readiness == .ready)
        #expect(store.memos.first?.isAwaitingTiers == false)
        // The metadata too, not only the status: an attachment that goes ready at null dimensions
        // keeps the fallback square its tile was laid out in, so the picture arrives in the wrong
        // box. 1000×1000 is what the feed said; 4032×3024 is what the worker measured.
        #expect(patched?.width == 4032)
        #expect(patched?.height == 3024)
        #expect(patched?.blurhash == "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
        #expect(patched?.measuredAspectRatio != 1)
    }

    // MARK: - the fence

    @Test("an event stamped for a generation the device has left is dropped")
    func aStaleGenerationEventIsDropped() async {
        let fixture = await loaded("pending")
        let store = fixture.store
        let identity = MediaIdentity()
        let stamped = envelope(Self.readyEvent, generation: identity.generation)

        // The device becomes another account between the event arriving and the consumer reaching
        // it — the window the stamp exists for. An attachment uid means nothing across accounts, so
        // applying this would patch the new account's timeline with the previous one's photo.
        identity.rotate()
        await consume([.event(stamped)], fixture, identity: identity)

        #expect(store.memos.first?.attachments.first?.readiness == .waiting)
        #expect(store.memos.first?.isAwaitingTiers == true)

        // The control: the SAME envelope against a clock that did not move DOES apply, so the drop
        // above is the fence working rather than the event being unusable.
        let unmoved = MediaIdentity()
        await consume([.event(stamped)], fixture, identity: unmoved)
        #expect(store.memos.first?.attachments.first?.readiness == .ready)
    }

    // MARK: - states

    @Test("a terminal stop ends the channel, and nothing behind it is applied")
    func aTerminalStopEndsTheChannel() async {
        let fixture = await loaded("pending")
        let store = fixture.store
        let identity = MediaIdentity()

        // The server refused the credential. Every stop reason is terminal, so the consumer goes
        // away rather than reading on — and an event queued behind the stop belongs to a channel
        // that has already ended.
        await consume(
            [
                .state(.open),
                .state(.stopped(.unauthorized)),
                .event(envelope(Self.readyEvent)),
            ],
            fixture,
            identity: identity
        )

        #expect(store.memos.first?.attachments.first?.readiness == .waiting)
        // The control: the same event WITHOUT the stop in front of it lands, so the silence above
        // is the teardown and not a stream the consumer cannot read.
        await consume(
            [.state(.open), .event(envelope(Self.readyEvent))],
            fixture,
            identity: identity
        )
        #expect(store.memos.first?.attachments.first?.readiness == .ready)
    }

    @Test("connecting, waiting and open say nothing to the timeline")
    func connectionStatesChangeNothing() async {
        let fixture = await loaded("pending")
        let store = fixture.store
        let before = store.memos

        await consume(
            [
                .state(.connecting(attempt: 1)),
                .state(.open),
                .state(.waiting(15)),
                .state(.connecting(attempt: 2)),
                .state(.waiting(1.5)),
            ],
            fixture,
            identity: MediaIdentity()
        )

        #expect(store.memos == before)
        #expect(store.lastError == nil, "a reconnect painted something on the timeline")
        #expect(!store.isLoading, "a reconnect put the timeline into a loading state")
    }

    @Test("an event that changes nothing visible is not written back to the timeline")
    func aProgressOnlyEventDoesNotWriteBack() async {
        // The percentage climbs about every one and a half seconds during a transcode and this app
        // shows no percentage, so these events are the common case and they change nothing a reader
        // can see. Writing the array back anyway would re-render the whole timeline for each one.
        let fixture = await loaded("processing")
        let store = fixture.store
        let identity = MediaIdentity()
        let observed = Box(false)

        withObservationTracking {
            _ = store.memos
        } onChange: {
            observed.value = true
        }
        await consume([.event(envelope(Self.processingEvent))], fixture, identity: identity)
        #expect(observed.value == false, "a progress event re-rendered the timeline")

        // The control: an event that DOES change something writes back, so the silence above is the
        // guard and not a tracking registration that never fired.
        let changing = Box(false)
        withObservationTracking {
            _ = store.memos
        } onChange: {
            changing.value = true
        }
        await consume([.event(envelope(Self.readyEvent))], fixture, identity: identity)
        #expect(changing.value == true)
        #expect(store.memos.first?.attachments.first?.readiness == .ready)
    }

    // MARK: - what one event does to an attachment

    @Test("a late in-flight event does not talk a finished attachment back into waiting")
    func aLateInFlightEventDoesNotUnreadyAnAttachment() async {
        // The stream is a poll: a `processing` snapshot taken before the job finished can be
        // delivered after the terminal event. Applying it would put a finished photo back under a
        // waiting treatment nothing will ever take off again — the job it describes is over and
        // will report nothing further.
        let fixture = await loaded("pending")
        let store = fixture.store
        let identity = MediaIdentity()

        await consume(
            [
                .event(envelope(Self.readyEvent)),
                .event(envelope(Self.processingEvent)),
            ],
            fixture,
            identity: identity
        )

        #expect(store.memos.first?.attachments.first?.readiness == .ready)
        #expect(store.memos.first?.attachments.first?.width == 4032)
    }

    @Test("a terminal event still applies to terminal state")
    func aRetriedAttachmentMayStillReachReady() async {
        // The other half of the same rule: `failed` is terminal, but a retried attachment does
        // legitimately reach `ready`, so terminal-to-terminal is not blocked.
        let fixture = await loaded("failed")
        let store = fixture.store
        #expect(store.memos.first?.attachments.first?.readiness == .failed)

        await consume([.event(envelope(Self.readyEvent))], fixture, identity: MediaIdentity())

        #expect(store.memos.first?.attachments.first?.readiness == .ready)
    }

    @Test("an event for an attachment nobody has loaded changes nothing")
    func anUnknownAttachmentIsIgnored() async {
        let fixture = await loaded("pending")
        let store = fixture.store
        let before = store.memos

        await consume(
            [.event(envelope(MediaEvent(uid: "not-loaded", status: .ready)))],
            fixture,
            identity: MediaIdentity()
        )

        #expect(store.memos == before)
    }

    @Test("the dimensions move as a pair or not at all")
    func dimensionsMoveAsAPair() {
        let attachment = MemoAttachment(
            uid: Self.attachment, mime: "image/jpeg", status: .pending, width: 1000, height: 1000
        )
        let memo = Memo(
            uid: Self.uid,
            owner: "fabian",
            mine: true,
            content: "hello",
            visibility: .private,
            pinned: false,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            attachments: [attachment]
        )

        // One dimension beside the other's stale value describes an aspect ratio neither source
        // has — and that ratio is exactly what the tile is laid out from.
        let halfMeasured = MediaEvent(uid: Self.attachment, status: .ready, width: 4032)
        let patched = applyMediaEvent(halfMeasured, to: [memo])[0].attachments[0]
        #expect(patched.readiness == .ready, "the status did not move")
        #expect(patched.width == 1000)
        #expect(patched.height == 1000)

        // The control: both halves present and both move.
        let measured = MediaEvent(uid: Self.attachment, status: .ready, width: 4032, height: 3024)
        let both = applyMediaEvent(measured, to: [memo])[0].attachments[0]
        #expect(both.width == 4032)
        #expect(both.height == 3024)
    }

    @Test("every live status maps to the model's own")
    func everyLiveStatusIsMapped() {
        // A case per input category: a mapping that silently collapses one of these is a tile stuck
        // in the wrong treatment, and there is no other place the two enums meet.
        #expect(AttachmentStatus(MediaAttachmentStatus.uploading) == .uploading)
        #expect(AttachmentStatus(MediaAttachmentStatus.pending) == .pending)
        #expect(AttachmentStatus(MediaAttachmentStatus.processing) == .processing)
        #expect(AttachmentStatus(MediaAttachmentStatus.ready) == .ready)
        #expect(AttachmentStatus(MediaAttachmentStatus.failed) == .failed)
        #expect(MediaAttachmentStatus.allCases.count == 5)
    }

    // MARK: - when the channel runs

    @Test("the channel runs in the foreground, signed in, with somewhere to put events")
    func theChannelRunsOnlyInTheForegroundAndSignedIn() {
        func runs(_ phase: MediaChannelPhase, _ signedIn: Bool, _ hasTimeline: Bool) -> Bool {
            MediaChannel.shouldRun(phase: phase, signedIn: signedIn, hasTimeline: hasTimeline)
        }

        // Ready on every count, a case per phase. `inactive` — the app switcher, the notification
        // shade, an incoming call — KEEPS it: the app comes straight back, and tearing the
        // connection down and building it up again across each of those is churn for its own sake.
        #expect(runs(.active, true, true))
        #expect(runs(.inactive, true, true))
        #expect(!runs(.background, true, true))

        // Signed out there is no credential to present, whatever the app is doing.
        #expect(!runs(.active, false, true))
        #expect(!runs(.inactive, false, true))
        #expect(!runs(.background, false, true))

        // And with no store there is nowhere to put an event. This is the launch instant, before
        // the task that builds the timeline has run — the condition lives in the rule so that the
        // store appearing FLIPS the decision, which is what starts the channel then. Keying a task
        // on a decision that ignored it would leave the channel dead for the whole session
        // whenever the two sibling tasks happened to run in the other order.
        #expect(!runs(.active, true, false))
        #expect(!runs(.inactive, true, false))
        #expect(!runs(.background, true, false))
    }

    // MARK: - the one thing the stream cannot say

    @Test("every connection open reconciles, and an idle-gap upload is not stranded")
    func everyConnectionOpenReconciles() async {
        // The hole a once-per-channel pass leaves. This client reconnects after each idle close,
        // and each connection's synthetic `ready` comes from a uid dropping out of the snapshot
        // THAT connection took. An attachment created and finished between two connections is in
        // no snapshot, so no event ever mentions it — and a reconcile taken when the channel
        // started predates it. Only a pass at each open sees it.
        let gets = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Self.memo("pending")]))
            case "get_memo_api_memos__uid__get":
                gets.increment()
                // Still working when the first connection opened; finished by the second — which
                // is exactly the state no event will ever report.
                return Stub.json(Self.memo(gets.count >= 2 ? "ready" : "processing"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)
        let fixture = Loaded(store: store, client: client, gets: gets)

        await consume(
            [
                .state(.connecting(attempt: 1)),
                .state(.open),
                .event(envelope(Self.processingEvent)),
                // The server ended the stream with nothing in flight; the client waits, then
                // opens a second connection. This is the gap.
                .state(.waiting(15)),
                .state(.connecting(attempt: 1)),
                .state(.open),
                // Nothing is waiting any more, so a third open must cost nothing.
                .state(.waiting(15)),
                .state(.connecting(attempt: 1)),
                .state(.open),
            ],
            fixture,
            identity: MediaIdentity()
        )

        // Twice, not once: the SECOND open is what found it, and no event carried that news.
        #expect(gets.count == 2, "opens reconciled \(gets.count) times, not twice")
        #expect(store.memos.first?.isAwaitingTiers == false, "the idle-gap upload stayed stranded")
        #expect(store.memos.first?.attachments.first?.readiness == .ready)
    }

    @Test("only the memos still waiting are reconciled when the channel starts")
    func onlyWaitingMemosAreReconciled() async {
        let gets = Counter()
        let asked = Box<[String]>([])
        let client = Stub.client { request, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(
                    Stub.page([
                        Self.memo("ready", uid: "settled", attachment: "a-settled"),
                        Self.memo("pending"),
                    ])
                )
            case "get_memo_api_memos__uid__get":
                gets.increment()
                asked.value.append(request.path ?? "")
                return Stub.json(Self.memo("ready"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(MediaChannel.uidsToReconcile(in: store.memos) == [Self.uid])

        await MediaChannel.reconcile(store, using: client, baseURL: Stub.baseURL)

        // ONE request: the settled memo is not re-read, and the waiting one is read exactly once —
        // this is a single pass, not the loop it replaced.
        #expect(gets.count == 1, "the reconciling pass asked \(gets.count) times, not once")
        #expect(asked.value.first?.contains(Self.uid) == true)
        #expect(store.memos.first(where: { $0.uid == Self.uid })?.isAwaitingTiers == false)

        // And starting the channel again now costs nothing at all: nothing is waiting.
        #expect(MediaChannel.uidsToReconcile(in: store.memos).isEmpty)
        await MediaChannel.reconcile(store, using: client, baseURL: Stub.baseURL)
        #expect(gets.count == 1, "a second start re-read a timeline with nothing waiting")
    }

    @Test("a memo is reconciled for any one attachment still waiting")
    func reconcileSelectsOnAnyWaitingAttachment() {
        func memo(_ uid: String, _ statuses: [AttachmentStatus]) -> Memo {
            Memo(
                uid: uid,
                owner: "fabian",
                mine: true,
                content: "hello",
                visibility: .private,
                pinned: false,
                createdAt: Date(timeIntervalSince1970: 1_750_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
                attachments: statuses.enumerated().map {
                    MemoAttachment(
                        uid: "\(uid)-\($0.offset)",
                        mime: "image/jpeg",
                        status: $0.element
                    )
                }
            )
        }

        let memos = [
            memo("none", []),
            memo("done", [.ready, .ready]),
            memo("mixed", [.ready, .pending]),
            memo("working", [.processing]),
            memo("sending", [.uploading, .ready]),
            // Nothing more is coming for a failed attachment, so it is not something to wait for.
            memo("givenup", [.ready, .failed]),
        ]

        #expect(MediaChannel.uidsToReconcile(in: memos) == ["mixed", "working", "sending"])
    }
}
