import Foundation
import Testing

@testable import MemosOutbox

/// The Live Activity's decisions, driven through the seam ActivityKit sits behind: the host here
/// records what it was asked to do, and the clock is a fake, so eight hours pass in a line.
private let dawn = Date(timeIntervalSince1970: 1_760_000_000)

private func upload(_ size: Int64, confirmed: Int64, id: UUID = UUID(), next: Date? = nil)
    -> OutboxFile
{
    OutboxFile(
        id: id, relativePath: "f", filename: "f.heic", mime: "image/heic", byteSize: size,
        uploadUID: "u", bytesConfirmed: confirmed, nextAttemptAt: next)
}

private func capture(
    _ files: [OutboxFile], state: JobState = .uploading, wait: WaitReason? = nil,
    hold: HoldReason? = nil, id: UUID = UUID()
) -> UploadJob {
    UploadJob(
        id: id, content: "Day at the lake", capturedAt: dawn, files: files,
        binding: Fixture.binding(), state: state, holdReason: hold, waitReason: wait)
}

/// The captures as the ledger hands them over: projected by the ledger's own rule.
private func read(_ jobs: [UploadJob], at now: Date) -> [TransferJob] {
    jobs.compactMap { TransferLedger.project($0, now: now) }
}

private func state(
    jobs: Int, files: (Int, Int), bytes: (Int64, Int64), _ status: TransferActivityStatus,
    settled: TransferSummary = .empty
) -> TransferActivityState {
    TransferActivityState(
        summary: sum(jobs: jobs, files: files, bytes: bytes), status: status, settled: settled)
}

private func sum(jobs: Int, files: (Int, Int), bytes: (Int64, Int64)) -> TransferSummary {
    TransferSummary(
        jobs: jobs, filesDone: files.0, filesTotal: files.1, bytesConfirmed: bytes.0,
        bytesTotal: bytes.1)
}

@MainActor
private final class RecordingHost: TransferActivityHosting {
    enum Call: Equatable {
        case start(String, TransferActivityState)
        case refused(TransferActivityState)
        case update(String, TransferActivityState)
        case end(String, TransferActivityState)
    }

    var calls: [Call] = []
    var refusing = false
    var survivors: [SurvivingTransferActivity] = []
    private var started = 0

    func start(_ state: TransferActivityState) -> TransferActivityHandle? {
        guard !refusing else {
            calls.append(.refused(state))
            return nil
        }
        started += 1
        let id = "activity-\(started)"
        calls.append(.start(id, state))
        return TransferActivityHandle(id: id)
    }

    func update(_ activity: TransferActivityHandle, to state: TransferActivityState) {
        calls.append(.update(activity.id, state))
    }

    func end(_ activity: TransferActivityHandle, on state: TransferActivityState) {
        calls.append(.end(activity.id, state))
    }

    func surviving() -> [SurvivingTransferActivity] { survivors }

    /// Every state one activity showed, from its start to its end, in order.
    func shown(by id: String) -> [TransferActivityState] {
        calls.compactMap { call in
            switch call {
            case .start(let activity, let state), .update(let activity, let state),
                .end(let activity, let state):
                activity == id ? state : nil
            case .refused: nil
            }
        }
    }
}

@MainActor
@Suite("Transfers Live Activity: when it starts, what it shows, when it ends")
struct TransferActivityTests {
    @Test("waiting for Wi-Fi overnight ends on paused, waiting for Wi-Fi; a byte restarts it")
    func overnightWaitEndsPausedAndTheFirstByteRestarts() {
        let clock = MutableClock(dawn)
        let host = RecordingHost()
        let driver = TransferActivityDriver(host: host, clock: { clock.now })
        let fileID = UUID()
        let jobID = UUID()
        func job(_ confirmed: Int64, _ state: JobState, _ wait: WaitReason? = nil) -> [TransferJob]
        {
            let job = capture(
                [upload(1000, confirmed: confirmed, id: fileID)], state: state, wait: wait,
                id: jobID)
            return read([job], at: clock.now)
        }
        // The first capture starts it.
        driver.observe(job(100, .uploading))
        // Off Wi-Fi with mobile data switched off: the queue waits, the island says why.
        clock.advance(30 * 60)
        driver.observe(job(300, .waiting, .homeNetwork))
        // Still waiting seven hours in: nothing to say, and no end yet.
        clock.advance(6.5 * 60 * 60)
        driver.observe(job(300, .waiting, .homeNetwork))
        // Morning: Wi-Fi is back past the ceiling, the queue is uploading, no byte confirmed yet.
        // The activity ends on the pause it was showing, and none starts on a capture alone.
        clock.advance(2 * 60 * 60)
        driver.observe(job(300, .uploading))
        clock.advance(10)
        driver.observe(job(300, .uploading))
        #expect(driver.shown == nil)
        // The first byte the server confirms starts the next one.
        clock.advance(50)
        driver.observe(job(400, .uploading))
        #expect(
            host.calls == [
                .start("activity-1", state(jobs: 1, files: (0, 1), bytes: (100, 1000), .sending)),
                .update(
                    "activity-1",
                    state(jobs: 1, files: (0, 1), bytes: (300, 1000), .paused(.waitingForWiFi))),
                .end(
                    "activity-1",
                    state(jobs: 1, files: (0, 1), bytes: (300, 1000), .paused(.waitingForWiFi))),
                .start("activity-2", state(jobs: 1, files: (0, 1), bytes: (400, 1000), .sending)),
            ])
        #expect(driver.shown == state(jobs: 1, files: (0, 1), bytes: (400, 1000), .sending))
    }

    @Test("a relaunched app updates the activity that survived it and never asks for another")
    func relaunchAdoptsTheSurvivingActivity() {
        let clock = MutableClock(dawn.addingTimeInterval(3600))
        let host = RecordingHost()
        // One capture (four files, 500 bytes) had landed; the one still queued was at 200.
        let landed = sum(jobs: 1, files: (3, 4), bytes: (500, 500))
        let shown = state(jobs: 2, files: (3, 5), bytes: (700, 1500), .sending, settled: landed)
        let stale = state(jobs: 1, files: (0, 1), bytes: (0, 10), .paused(.held))
        host.survivors = [
            SurvivingTransferActivity(
                handle: TransferActivityHandle(id: "older"), startedAt: dawn, state: stale),
            SurvivingTransferActivity(
                handle: TransferActivityHandle(id: "newest"),
                startedAt: dawn.addingTimeInterval(600), state: shown),
        ]
        // A background relaunch for an upload's events: a new process, a new driver.
        let driver = TransferActivityDriver(host: host, clock: { clock.now })
        #expect(host.calls == [.end("older", stale)])
        #expect(driver.shown == shown)
        // Its first read sees only the capture still queued: what had landed is kept as it was,
        // and the queued capture counts on top of it.
        let still = capture([upload(1000, confirmed: 900)])
        driver.observe(read([still], at: clock.now))
        #expect(
            host.calls == [
                .end("older", stale),
                .update(
                    "newest",
                    state(
                        jobs: 2, files: (3, 5), bytes: (1400, 1500), .sending, settled: landed)),
            ])
        // The ceiling counts from when the surviving activity started, not from the relaunch.
        clock.advance(TransferActivityDriver.ceiling - TransferActivityDriver.renewalMargin - 3000)
        driver.observe(read([still], at: clock.now))
        #expect(
            host.calls.last
                == .end(
                    "newest",
                    state(
                        jobs: 2, files: (3, 5), bytes: (1400, 1500), .paused(nil),
                        settled: landed)))
        #expect(!host.calls.contains { if case .start = $0 { true } else { false } })
    }

    @Test(
        "after a relaunch, what had landed is carried as it was and the queue still ends whole",
        arguments: [50, 80] as [Int64])
    func relaunchCarriesWhatFinishedUnseen(firstRead: Int64) {
        let clock = MutableClock(dawn)
        let host = RecordingHost()
        // A (100 bytes) landed and left the queue in a process that is gone; B was half sent.
        // With `firstRead` 80, B moved on before the relaunched process read the queue at all.
        let landed = sum(jobs: 1, files: (1, 1), bytes: (100, 100))
        let adopted = state(jobs: 2, files: (1, 2), bytes: (150, 200), .sending, settled: landed)
        host.survivors = [
            SurvivingTransferActivity(
                handle: TransferActivityHandle(id: "survivor"), startedAt: dawn, state: adopted)
        ]
        let driver = TransferActivityDriver(host: host, clock: { clock.now })
        let b = UUID()
        let bFile = UUID()
        let reads: [(Int64, JobState)] = [
            (firstRead, .uploading), (90, .uploading), (100, .creating),
        ]
        for (confirmed, state) in reads {
            clock.advance(5)
            let job = capture([upload(100, confirmed: confirmed, id: bFile)], state: state, id: b)
            driver.observe(read([job], at: clock.now))
        }
        clock.advance(5)
        driver.observe([])
        let shown = [adopted] + host.shown(by: "survivor")
        for (before, after) in zip(shown, shown.dropFirst()) {
            #expect(after.summary.filesDone >= before.summary.filesDone)
            #expect(after.summary.bytesConfirmed >= before.summary.bytesConfirmed)
            #expect(after.summary.bytesTotal >= before.summary.bytesTotal)
        }
        let whole = sum(jobs: 2, files: (2, 2), bytes: (200, 200))
        #expect(
            host.calls.last
                == .end(
                    "survivor",
                    state(
                        jobs: 2, files: (2, 2), bytes: (200, 200), .finished, settled: whole)))
        // Every byte B confirmed shows on top of A, the first adopted read included; a read
        // that repeats what the survivor already showed changes nothing.
        let confirmed = Set(host.shown(by: "survivor").map(\.summary.bytesConfirmed))
        #expect(confirmed == Set([100 + firstRead, 190, 200].filter { $0 > 150 }))
    }

    @Test("a read past the ceiling that already confirmed a byte ends the old one and starts anew")
    func ceilingWithBytesMovingRollsOver() {
        let clock = MutableClock(dawn)
        let host = RecordingHost()
        let driver = TransferActivityDriver(host: host, clock: { clock.now })
        let fileID = UUID()
        let jobID = UUID()
        func job(_ confirmed: Int64, _ state: JobState, _ wait: WaitReason? = nil) -> [TransferJob]
        {
            let job = capture(
                [upload(1000, confirmed: confirmed, id: fileID)], state: state, wait: wait,
                id: jobID)
            return read([job], at: clock.now)
        }
        driver.observe(job(100, .waiting, .noNetwork))
        clock.advance(TransferActivityDriver.ceiling + 60)
        driver.observe(job(200, .uploading))
        #expect(
            host.calls == [
                .start(
                    "activity-1",
                    state(jobs: 1, files: (0, 1), bytes: (100, 1000), .paused(.noConnection))),
                .end(
                    "activity-1",
                    state(jobs: 1, files: (0, 1), bytes: (200, 1000), .paused(.noConnection))),
                .start("activity-2", state(jobs: 1, files: (0, 1), bytes: (200, 1000), .sending)),
            ])
    }

    @Test("the counts only ever rise within one activity: a capture leaving, a file starting over")
    func countsOnlyRiseWithinOneActivity() {
        let clock = MutableClock(dawn)
        let host = RecordingHost()
        let driver = TransferActivityDriver(host: host, clock: { clock.now })
        let (a, b, a1, a2, b1) = (UUID(), UUID(), UUID(), UUID(), UUID())
        func jobA(_ first: Int64, _ second: Int64, _ state: JobState = .uploading) -> UploadJob {
            capture(
                [upload(100, confirmed: first, id: a1), upload(200, confirmed: second, id: a2)],
                state: state, id: a)
        }
        func jobB(_ confirmed: Int64) -> UploadJob {
            capture([upload(500, confirmed: confirmed, id: b1)], id: b)
        }
        let reads: [[UploadJob]] = [
            [jobA(50, 0), jobB(0)],
            [jobA(100, 100), jobB(400)],
            // The background session lost B's file and it starts over from zero.
            [jobA(100, 200, .creating), jobB(0)],
            // A is a memo now and leaves the queue, taking its files out of the ledger's sums.
            [jobB(100)],
            [jobB(500)],
            [],
        ]
        var raw: [TransferSummary] = []
        for jobs in reads {
            clock.advance(5)
            let projected = read(jobs, at: clock.now)
            let files = projected.flatMap(\.files)
            raw.append(
                TransferSummary(
                    jobs: projected.count, filesDone: files.count(where: { $0.state == .done }),
                    filesTotal: files.count,
                    bytesConfirmed: files.reduce(0) { $0 + $1.bytesConfirmed },
                    bytesTotal: files.reduce(0) { $0 + $1.byteSize }))
            driver.observe(projected)
        }
        // The ledger's own numbers fall — the test would prove nothing if they did not.
        #expect(raw[2].bytesConfirmed < raw[1].bytesConfirmed)
        #expect(raw[3].filesDone < raw[2].filesDone)
        #expect(raw[3].filesTotal < raw[2].filesTotal)
        let shown = host.shown(by: "activity-1")
        // A start, an update for every read that changed the content state, and the end. A
        // leaving keeps every number on screen, yet still writes one update: its counts move
        // into the settled part, which is what a relaunched process adopts.
        #expect(shown.count == 6)
        #expect(shown[3].summary == shown[2].summary)
        #expect(shown[3].settled.jobs == 1 && shown[2].settled == .empty)
        for (before, after) in zip(shown, shown.dropFirst()) {
            #expect(after.summary.jobs >= before.summary.jobs)
            #expect(after.summary.filesDone >= before.summary.filesDone)
            #expect(after.summary.filesTotal >= before.summary.filesTotal)
            #expect(after.summary.bytesConfirmed >= before.summary.bytesConfirmed)
            #expect(after.summary.bytesTotal >= before.summary.bytesTotal)
        }
        #expect(shown.last?.summary == sum(jobs: 2, files: (3, 3), bytes: (800, 800)))
        #expect(shown.last?.status == .finished)
        // Everything left the queue, so all of it has settled.
        #expect(shown.last?.settled == shown.last?.summary)
        #expect(driver.shown == nil)
    }

    @Test("a read inside the renewal margin ends the activity; one a second before it updates")
    func renewalMarginBoundary() {
        let clock = MutableClock(dawn)
        let host = RecordingHost()
        let driver = TransferActivityDriver(host: host, clock: { clock.now })
        let job = capture([upload(1000, confirmed: 0)], state: .held, hold: .tooLarge)
        driver.observe(read([job], at: clock.now))
        let edge = TransferActivityDriver.ceiling - TransferActivityDriver.renewalMargin
        clock.advance(edge - 1)
        let waiting = capture(
            [upload(1000, confirmed: 0)], state: .waiting, wait: .videoOverMobileLimit, id: job.id)
        driver.observe(read([waiting], at: clock.now))
        #expect(driver.shown?.status == .paused(.waitingForWiFi))
        clock.advance(1)
        driver.observe(read([waiting], at: clock.now))
        #expect(driver.shown == nil)
        #expect(
            host.calls.last
                == .end(
                    "activity-1",
                    state(jobs: 1, files: (0, 1), bytes: (0, 1000), .paused(.waitingForWiFi))))
        #expect(host.calls.count == 3)
    }

    @Test("a start the system refuses is asked again on the next read, bytes or none")
    func refusedStartIsAskedAgain() {
        let clock = MutableClock(dawn)
        let host = RecordingHost()
        let driver = TransferActivityDriver(host: host, clock: { clock.now })
        let fileID = UUID()
        let jobID = UUID()
        func job(_ confirmed: Int64) -> [TransferJob] {
            read(
                [capture([upload(1000, confirmed: confirmed, id: fileID)], id: jobID)],
                at: clock.now)
        }
        // An empty queue starts nothing.
        driver.observe([])
        #expect(host.calls.isEmpty)
        driver.observe(job(10))
        clock.advance(TransferActivityDriver.ceiling)
        driver.observe(job(10))
        #expect(driver.shown == nil)
        // The first byte after the ceiling comes while the app is in the background: refused.
        host.refusing = true
        clock.advance(5)
        driver.observe(job(20))
        // The app comes to the front with no byte moving since: the start is asked for again,
        // because a refusal is the system saying "not now", not the queue saying "nothing moved".
        host.refusing = false
        clock.advance(5)
        driver.observe(job(20))
        #expect(
            host.calls.map {
                switch $0 {
                case .start(let id, _): "start \(id)"
                case .refused: "refused"
                case .update(let id, _): "update \(id)"
                case .end(let id, _): "end \(id)"
                }
            } == ["start activity-1", "end activity-1", "refused", "start activity-2"])
        #expect(driver.shown == state(jobs: 1, files: (0, 1), bytes: (20, 1000), .sending))
    }

    struct StatusCase: Sendable, CustomTestStringConvertible {
        var states: [JobState]
        var waits: [WaitReason?]
        var want: TransferActivityStatus
        var testDescription: String { "\(states) \(waits) -> \(want)" }
    }

    @Test(
        "the pause named is the oldest capture's, and anything sending reads sending",
        arguments: [
            StatusCase(states: [.waiting], waits: [.homeNetwork], want: .paused(.waitingForWiFi)),
            StatusCase(
                states: [.waiting], waits: [.videoOverMobileLimit], want: .paused(.waitingForWiFi)),
            StatusCase(states: [.waiting], waits: [.noNetwork], want: .paused(.noConnection)),
            StatusCase(states: [.waiting], waits: [.retrying], want: .paused(.retrying)),
            StatusCase(states: [.waiting], waits: [nil], want: .paused(nil)),
            StatusCase(states: [.held], waits: [nil], want: .paused(.held)),
            StatusCase(
                states: [.held, .waiting], waits: [nil, .homeNetwork], want: .paused(.held)),
            StatusCase(states: [.waiting, .uploading], waits: [.noNetwork, nil], want: .sending),
            StatusCase(states: [.creating], waits: [nil], want: .sending),
            StatusCase(states: [], waits: [], want: .paused(nil)),
        ])
    func statusTable(_ check: StatusCase) {
        let jobs = zip(check.states, check.waits).map { state, wait in
            capture(
                [upload(10, confirmed: 0)], state: state, wait: wait,
                hold: state == .held ? .tooLarge : nil)
        }
        #expect(TransferActivityDriver.status(of: read(jobs, at: dawn)) == check.want)
    }

    @Test("a file spacing out a failed send reads paused, retrying, unless another one is sending")
    func spacingIsAPauseOnlyWhileNothingSends() {
        let later = dawn.addingTimeInterval(30)
        let spacing = upload(10, confirmed: 2, next: later)
        #expect(
            TransferActivityDriver.status(of: read([capture([spacing])], at: dawn))
                == .paused(.retrying))
        let beside = capture([spacing, upload(10, confirmed: 0)])
        #expect(TransferActivityDriver.status(of: read([beside], at: dawn)) == .sending)
    }

    @Test("the ledger hands on every read it applied and none it refused: a late one never shows")
    func ledgerFeedsTheDriverOnlyWhatItApplied() {
        let clock = MutableClock(dawn)
        let host = RecordingHost()
        let driver = TransferActivityDriver(host: host, clock: { clock.now })
        let ledger = TransferLedger(clock: { clock.now })
        ledger.onApplied = { driver.observe($0) }
        let id = UUID()
        let fileID = UUID()
        let half = capture([upload(1000, confirmed: 500, id: fileID)], id: id)
        // Read 2 began after the capture became a memo and found the queue empty; read 1, begun
        // earlier, saw it half sent and lands last. Only read 2 reaches the activity.
        #expect(ledger.apply([half], generation: 1))
        #expect(ledger.apply([], generation: 3))
        #expect(ledger.apply([half], generation: 2) == false)
        #expect(
            host.calls == [
                .start("activity-1", state(jobs: 1, files: (0, 1), bytes: (500, 1000), .sending)),
                .end(
                    "activity-1",
                    state(
                        jobs: 1, files: (0, 1), bytes: (500, 1000), .finished,
                        settled: sum(jobs: 1, files: (0, 1), bytes: (500, 1000)))),
            ])
        #expect(driver.shown == nil)
    }
}
