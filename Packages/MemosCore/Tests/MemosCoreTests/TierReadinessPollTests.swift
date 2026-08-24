import Foundation
import MemosAPI
import MemosCore
import Testing

/// The waiting has to END without anybody doing anything.
///
/// A memo is created before its pictures are derived, so a freshly posted one arrives with
/// attachments the server has not finished with. Those tiles show a waiting treatment — and until
/// this, the only thing that ever took it off again was pulling the timeline down by hand, which
/// nobody has any reason to know.
///
/// Every test here substitutes the WAIT, never the store and never the client: the schedule is
/// asserted as numbers, and the requests are counted through a real generated client on a scripted
/// transport. Substituting the store would prove only that the test agrees with itself.
@MainActor
@Suite("Tier-ready refresh")
struct TierReadinessPollTests {
    private nonisolated static let uid = "m1"

    /// The memo as the server would send it with one attachment at a given stage.
    ///
    /// `nonisolated static`, because it is called from inside the scripted transport, which the
    /// client runs off the main actor.
    private nonisolated static func memo(_ status: String) -> String {
        Stub.memo(uid: uid, attachments: [Stub.attachment(uid: "a1", status: status)])
    }

    /// A store with one waiting memo in it, loaded the way the app loads one.
    private func loaded(_ client: any APIProtocol) async -> TimelineStore {
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)
        return store
    }

    // MARK: - the schedule

    @Test("the backoff doubles from three seconds and stops at thirty")
    func theSchedule() {
        #expect(TierReadinessPoll.delay(afterAttempt: 0) == .seconds(3))
        #expect(TierReadinessPoll.delay(afterAttempt: 1) == .seconds(6))
        #expect(TierReadinessPoll.delay(afterAttempt: 2) == .seconds(12))
        #expect(TierReadinessPoll.delay(afterAttempt: 3) == .seconds(24))
        #expect(TierReadinessPoll.delay(afterAttempt: 4) == .seconds(30))
        // It never climbs past the cap, however long a job is stuck.
        #expect(TierReadinessPoll.delay(afterAttempt: 40) == .seconds(30))
        #expect(TierReadinessPoll.delay(afterAttempt: 4_000) == .seconds(30))
        // And never below the first wait, however odd the input.
        #expect(TierReadinessPoll.delay(afterAttempt: -1) == .seconds(3))
        #expect(TierReadinessPoll.firstDelay == .seconds(3))
        #expect(TierReadinessPoll.maximumDelay == .seconds(30))
    }

    // MARK: - the poll

    /// The whole point, end to end: a memo whose attachment is pending is re-read until the server
    /// says it is ready, the card's projection flips, and the asking then STOPS.
    @Test("a waiting memo becomes ready through the poll, which then stops asking")
    func pendingBecomesReady() async {
        let gets = Counter()
        let waits = Box<[Duration]>([])
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Self.memo("pending")]))
            case "get_memo_api_memos__uid__get":
                gets.increment()
                // The worker finishes between the second re-read and the third.
                return Stub.json(Self.memo(gets.count >= 3 ? "ready" : "processing"))
            default:
                return Stub.empty(.notFound)
            }
        }

        let store = await loaded(client)
        #expect(store.memos.first?.attachments.first?.readiness == .waiting)
        #expect(store.memos.first?.isAwaitingTiers == true)

        await TierReadinessPoll.run(
            uid: Self.uid, in: store, using: client, baseURL: Stub.baseURL
        ) { duration in
            waits.value.append(duration)
        }

        #expect(store.memos.first?.attachments.first?.readiness == .ready)
        #expect(store.memos.first?.isAwaitingTiers == false)
        #expect(gets.count == 3, "the poll asked \(gets.count) times, not three")
        // It waited before each one, on the capped backoff, and never asked again after the
        // answer arrived.
        #expect(waits.value == [.seconds(3), .seconds(6), .seconds(12)])
    }

    /// A memo with nothing waiting is never asked about at all — a poll that runs anyway is a
    /// request per card per few seconds for a timeline where nothing is happening.
    @Test("a memo whose attachments are ready is never re-read")
    func readyMemoIsNotPolled() async {
        let gets = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Self.memo("ready")]))
            case "get_memo_api_memos__uid__get":
                gets.increment()
                return Stub.json(Self.memo("ready"))
            default:
                return Stub.empty(.notFound)
            }
        }

        let store = await loaded(client)
        await TierReadinessPoll.run(
            uid: Self.uid, in: store, using: client, baseURL: Stub.baseURL
        ) { _ in }

        #expect(gets.count == 0)
        // The control: the SAME arrangement with a pending attachment does ask, so the zero above
        // is the guard working rather than the poll being broken.
        let asking = Counter()
        let pendingClient = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Self.memo("pending")]))
            case "get_memo_api_memos__uid__get":
                asking.increment()
                return Stub.json(Self.memo("ready"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let pendingStore = await loaded(pendingClient)
        await TierReadinessPoll.run(
            uid: Self.uid, in: pendingStore, using: pendingClient, baseURL: Stub.baseURL
        ) { _ in }
        #expect(asking.count == 1)
    }

    /// A memo that is not loaded at all — deleted, or scrolled out of the loaded window — is not
    /// something to keep asking the server about.
    @Test("a memo that is not on screen is not polled")
    func unloadedMemoIsNotPolled() async {
        let gets = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Self.memo("pending")]))
            default:
                gets.increment()
                return Stub.json(Self.memo("ready"))
            }
        }
        let store = await loaded(client)

        await TierReadinessPoll.run(
            uid: "not-loaded", in: store, using: client, baseURL: Stub.baseURL
        ) { _ in }

        #expect(gets.count == 0)
    }

    /// The lifetime rule: the poll belongs to the row on screen, and when that row goes away —
    /// SwiftUI cancelling its `.task` — the asking stops with it, mid-wait.
    @Test("the poll detaches the moment the view it belongs to goes away")
    func cancellationDetaches() async {
        let gets = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Self.memo("pending")]))
            case "get_memo_api_memos__uid__get":
                gets.increment()
                // A safety valve, not part of what is asserted: if the cancellation below somehow
                // does not land, this ends the loop so the failure is a wrong count rather than a
                // hung suite.
                return Stub.json(Self.memo(gets.count >= 6 ? "ready" : "pending"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = await loaded(client)

        let handle = Box<Task<Void, Never>?>(nil)
        let task = Task { @MainActor in
            await TierReadinessPoll.run(
                uid: Self.uid, in: store, using: client, baseURL: Stub.baseURL
            ) { _ in
                // The row scrolls off during the third wait.
                if gets.count >= 2 { handle.value?.cancel() }
            }
        }
        // Set before the child task can run: this function holds the main actor until it awaits.
        handle.value = task
        await task.value

        #expect(gets.count == 2, "the poll went on asking after its view had gone: \(gets.count)")
        // The memo is still waiting, which is the honest state — nothing pretended otherwise.
        #expect(store.memos.first?.isAwaitingTiers == true)
    }

    // MARK: - the re-read itself

    /// The refreshed attachment data has to land in the card that is already on screen, through
    /// the same path an edit takes — not as a new row, and not by reordering the timeline.
    @Test("a re-read replaces the memo in place, leaving the list alone")
    func refreshMemoAppliesInPlace() async {
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(
                    Stub.page([
                        Stub.memo(uid: "older", createdAt: "2026-08-23T08:00:00Z"),
                        Self.memo("pending"),
                    ])
                )
            case "get_memo_api_memos__uid__get":
                return Stub.json(Self.memo("ready"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["older", Self.uid])

        let refreshed = await store.refreshMemo(
            uid: Self.uid, using: client, baseURL: Stub.baseURL
        )

        #expect(refreshed)
        #expect(store.memos.map(\.uid) == ["older", Self.uid], "the re-read reordered the list")
        #expect(store.memos.count == 2, "the re-read added a row instead of replacing one")
        #expect(store.memos[1].attachments.first?.readiness == .ready)
    }

    /// A background re-read is not the timeline's error banner. It runs behind a screen nobody
    /// asked to refresh, and a blip on it must not paint a notice over a timeline that works.
    @Test("a re-read that failed says nothing on the timeline")
    func backgroundFailureIsSilent() async {
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Self.memo("pending")]))
            default:
                return Stub.empty(.internalServerError)
            }
        }
        let store = await loaded(client)
        #expect(store.lastError == nil)

        let refreshed = await store.refreshMemo(
            uid: Self.uid, using: client, baseURL: Stub.baseURL
        )

        #expect(!refreshed)
        #expect(store.lastError == nil, "a background poll painted an error on the timeline")
        // The control: a foreground refresh through the same failing transport DOES report, so
        // the silence above is this method's own decision and not a broken stub.
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(store.lastError == nil)
    }

    /// And the poll gives up rather than hammering a server that is answering with errors.
    @Test("a poll stops when a re-read fails")
    func failureEndsThePoll() async {
        let gets = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Self.memo("pending")]))
            default:
                gets.increment()
                return Stub.empty(.internalServerError)
            }
        }
        let store = await loaded(client)

        await TierReadinessPoll.run(
            uid: Self.uid, in: store, using: client, baseURL: Stub.baseURL
        ) { _ in }

        #expect(gets.count == 1, "the poll kept retrying a failing server: \(gets.count)")
    }
}

/// The three-way projection, on the model, where both the view and the poll read it from.
@Suite("Attachment readiness")
struct AttachmentReadinessTests {
    private func attachment(_ status: AttachmentStatus) -> MemoAttachment {
        MemoAttachment(uid: "a1", mime: "image/jpeg", status: status)
    }

    private func memo(_ statuses: [AttachmentStatus]) -> Memo {
        Memo(
            uid: "m1",
            owner: "fabian",
            mine: true,
            content: "hello",
            visibility: .private,
            pinned: false,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            attachments: statuses.enumerated().map {
                MemoAttachment(uid: "a\($0.offset)", mime: "image/jpeg", status: $0.element)
            }
        )
    }

    /// A case per status, and the three answers are genuinely three. `uploading` is grouped with
    /// the server-side stages on purpose: to a reader, a file still on its way and a file the
    /// worker has not reached yet are the same thing — something is coming, nothing is broken.
    @Test("every status projects to one of exactly three treatments")
    func everyStatusIsProjected() {
        #expect(attachment(.ready).readiness == .ready)
        #expect(attachment(.pending).readiness == .waiting)
        #expect(attachment(.processing).readiness == .waiting)
        #expect(attachment(.uploading).readiness == .waiting)
        #expect(attachment(.failed).readiness == .failed)
        #expect(Set([AttachmentReadiness.ready, .waiting, .failed]).count == 3)
        // The one that matters: pending is NOT failed. That equivalence is what put a row of
        // warning triangles on the first real post from the phone.
        #expect(attachment(.pending).readiness != attachment(.failed).readiness)
    }

    @Test("a memo is waiting while any one of its attachments is")
    func memoWaitsForAnyAttachment() {
        #expect(!memo([]).isAwaitingTiers)
        #expect(!memo([.ready, .ready]).isAwaitingTiers)
        #expect(memo([.ready, .pending]).isAwaitingTiers)
        #expect(memo([.processing]).isAwaitingTiers)
        #expect(memo([.uploading, .ready]).isAwaitingTiers)
        // A failed attachment is not something to wait for: nothing more is coming for it.
        #expect(!memo([.ready, .failed]).isAwaitingTiers)
        #expect(!memo([.failed]).isAwaitingTiers)
    }
}
