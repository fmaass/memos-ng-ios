import Foundation
import Testing

@testable import MemosOutbox

/// The ledger is fed the manifests the queue read, and nothing else: these build those manifests
/// by hand and read back what the ledger says about each file.
private let start = Date(timeIntervalSince1970: 1_760_000_000)

private func file(
    _ name: String, size: Int64, confirmed: Int64, uid: String? = "u", next: Date? = nil
) -> OutboxFile {
    OutboxFile(
        relativePath: name, filename: name, mime: "image/heic", byteSize: size,
        uploadUID: uid, bytesConfirmed: confirmed, nextAttemptAt: next)
}

private func job(
    _ files: [OutboxFile], state: JobState = .uploading, hold: HoldReason? = nil,
    wait: WaitReason? = nil, next: Date = .distantPast, id: UUID = UUID()
) -> UploadJob {
    UploadJob(
        id: id, content: "Day at the lake", capturedAt: start, files: files,
        binding: Fixture.binding(), state: state, holdReason: hold, waitReason: wait,
        nextAttemptAt: next)
}

@MainActor
@Suite("Transfer ledger: bytes, state and reason per file")
struct TransferLedgerProjectionTests {
    @Test("a manifest set reads back as bytes, state and reason for every file")
    func manifestSetPerFile() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        let retryAt = start.addingTimeInterval(8)
        let moving = file("a.heic", size: 1000, confirmed: 400)
        let done = file("b.heic", size: 500, confirmed: 500)
        let spacing = file("c.mov", size: 2000, confirmed: 100, next: retryAt)
        let held = file("d.mov", size: 3000, confirmed: 0, uid: nil)
        let waiting = file("e.heic", size: 10, confirmed: 0, uid: nil)
        let manifests = [
            job([moving, done, spacing]),
            job([held], state: .held, hold: .tooLarge),
            job([waiting], state: .waiting, wait: .homeNetwork),
        ]
        #expect(ledger.apply(manifests, generation: 1))
        let files = ledger.jobs.flatMap(\.files)
        #expect(files.map(\.bytesConfirmed) == [400, 500, 100, 0, 0])
        #expect(files.map(\.state) == [.uploading, .done, .waiting, .held, .waiting])
        #expect(
            files.map(\.reason) == [
                nil, nil, .retrying(until: retryAt), .held(.tooLarge), .waiting(.homeNetwork),
            ])
        #expect(files.map(\.reason?.retryClass) == [nil, nil, .transient, .hold, .connectivity])
        #expect(files[2].nextAttemptAt == retryAt)
        #expect(files[0].fraction == 0.4)
        #expect(
            ledger.summary
                == TransferSummary(
                    jobs: 3, filesDone: 1, filesTotal: 5, bytesConfirmed: 1000, bytesTotal: 6510))
    }

    @Test("a waiting capture's retry date is the file's, and a date already past is none")
    func waitingCarriesTheScheduleDate() {
        let later = start.addingTimeInterval(32)
        let waiting = job(
            [file("a", size: 10, confirmed: 0, uid: nil)], state: .waiting, wait: .retrying,
            next: later)
        let projected = TransferLedger.project(waiting, now: start)
        #expect(projected?.files.first?.nextAttemptAt == later)
        #expect(projected?.files.first?.reason == .waiting(.retrying))
        let past = TransferLedger.project(waiting, now: later.addingTimeInterval(1))
        #expect(past?.files.first?.nextAttemptAt == nil)
    }

    @Test("bytes the manifest overstates are clamped to the file's size")
    func confirmedIsClamped() {
        let over = job([file("a", size: 100, confirmed: 250)], state: .waiting)
        let projected = TransferLedger.project(over, now: start)
        #expect(projected?.files.first?.bytesConfirmed == 100)
    }

    @Test("a capture taken back to the editor is a draft, not a transfer")
    func cancelledIsNotATransfer() {
        var taken = job([file("a", size: 100, confirmed: 0)], state: .waiting)
        taken.cancelledAt = start
        #expect(TransferLedger.project(taken, now: start) == nil)
    }

    @Test("an empty file counts as whole only once it is done")
    func emptyFileFraction() {
        let empty = TransferFile(
            id: UUID(), filename: "e", byteSize: 0, bytesConfirmed: 0, state: .waiting,
            reason: nil, nextAttemptAt: nil)
        #expect(empty.fraction == 0)
        let whole = TransferFile(
            id: UUID(), filename: "e", byteSize: 0, bytesConfirmed: 0, state: .done,
            reason: nil, nextAttemptAt: nil)
        #expect(whole.fraction == 1)
    }

    @Test("a capture held after every byte landed reads held, its bytes whole")
    func heldAfterUploadWins() {
        let sent = job(
            [file("a", size: 100, confirmed: 100), file("b", size: 50, confirmed: 50)],
            state: .held, hold: .signInRequired)
        let files = TransferLedger.project(sent, now: start)?.files ?? []
        #expect(files.map(\.state) == [.held, .held])
        #expect(files.map(\.reason) == [.held(.signInRequired), .held(.signInRequired)])
        #expect(files.map(\.bytesConfirmed) == [100, 50])
        let waiting = job(
            [file("a", size: 100, confirmed: 100)], state: .waiting, wait: .noNetwork)
        #expect(TransferLedger.project(waiting, now: start)?.files.first?.state == .waiting)
    }

    @Test("a creating capture's files are all done")
    func creatingIsDone() {
        let creating = job([file("a", size: 100, confirmed: 100, uid: nil)], state: .creating)
        #expect(TransferLedger.project(creating, now: start)?.files.first?.state == .done)
    }
}

@MainActor
@Suite("Transfer ledger: a state the planner left is never resurrected")
struct TransferLedgerFenceTests {
    @Test("a late read, issued before the planner moved on, changes nothing")
    func lateReadIsRefused() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        let id = UUID()
        let half = job([file("a", size: 1000, confirmed: 500)], id: id)
        // Read 1 began first and saw the file half sent; read 2 began after the planner finished
        // the capture and found the queue empty. Read 2 lands first.
        #expect(ledger.apply([], generation: 2) == true)
        #expect(ledger.apply([half], generation: 1) == false)
        #expect(ledger.jobs.isEmpty)
        #expect(ledger.generation == 2)
        // The same holds for a file the planner confirmed: a late half does not undo it.
        let whole = job([file("a", size: 1000, confirmed: 1000)], state: .creating, id: id)
        #expect(ledger.apply([whole], generation: 3))
        #expect(ledger.apply([half], generation: 3) == false)
        #expect(ledger.jobs.first?.files.first?.state == .done)
        #expect(ledger.jobs.first?.files.first?.bytesConfirmed == 1000)
    }

    @Test("the outbox hands the ledger every read it applies, under that read's ticket")
    func outboxFeedsTheLedger() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = StaticCredentials(credentials: Fixture.credentials())
        let repository = try OutboxRepository(
            root: root, stillCurrent: { credentials.stillCurrent(epoch: $0) })
        let (preferences, name) = Fixture.preferences()
        defer { Fixture.forgetting(name) }
        let outbox = Outbox(
            repository: repository,
            credentials: credentials,
            http: ScriptedHTTP.standard(health: 500),
            scheduler: ScriptedScheduler(),
            completion: ScriptedCompletion([.retry("not now")], repeating: .retry("not now")),
            network: StubNetworkPath(),
            preferences: preferences
        )
        let held = job([file("a", size: 10, confirmed: 4)], state: .held, hold: .tooLarge)
        try await repository.save(held)
        await outbox.refresh()
        #expect(outbox.transfers.jobs.map(\.id) == [held.id])
        #expect(outbox.transfers.jobs.first?.files.first?.reason == .held(.tooLarge))
        let first = outbox.transfers.generation
        await outbox.refresh()
        #expect(outbox.transfers.generation == first + 1)
    }
}

@MainActor
@Suite("Transfer ledger: rates and ETAs")
struct TransferLedgerETATests {
    private func uploading(_ confirmed: Int64, size: Int64 = 10_000, id: UUID, fileID: UUID)
        -> UploadJob
    {
        var one = file("a", size: size, confirmed: confirmed)
        one.id = fileID
        return job([one], id: id)
    }

    @Test("no ETA under two confirmations, a time after two")
    func twoConfirmations() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        let (id, fileID) = (UUID(), UUID())
        ledger.apply([uploading(0, id: id, fileID: fileID)], generation: 1)
        #expect(ledger.estimate(at: clock.now) == .unknown)
        clock.advance(10)
        ledger.apply([uploading(1000, id: id, fileID: fileID)], generation: 2)
        // One confirmation is a size, not a rate.
        #expect(ledger.estimate(at: clock.now) == .unknown)
        clock.advance(10)
        ledger.apply([uploading(2000, id: id, fileID: fileID)], generation: 3)
        // 1000 bytes in 10 s, 8000 left: 80 s.
        #expect(ledger.estimate(at: clock.now) == .remaining(80))
    }

    @Test("a held capture's bytes are not divided by the rate: they never move")
    func heldBytesAreNotInTheEstimate() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        let (id, fileID) = (UUID(), UUID())
        let stuck = job(
            [file("big.mov", size: 1_000_000, confirmed: 0, uid: nil)], state: .held,
            hold: .tooLarge)
        ledger.apply([uploading(0, id: id, fileID: fileID), stuck], generation: 1)
        clock.advance(10)
        ledger.apply([uploading(1000, id: id, fileID: fileID), stuck], generation: 2)
        clock.advance(10)
        ledger.apply([uploading(2000, id: id, fileID: fileID), stuck], generation: 3)
        // 1000 bytes in 10 s, 8000 of the moving file left: 80 s, the held million ignored.
        #expect(ledger.estimate(at: clock.now) == .remaining(80))
    }

    @Test("a confirmed count the planner reset to zero is no confirmation, and others still count")
    func resetIsNoConfirmation() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        let (id, a, b) = (UUID(), UUID(), UUID())
        func read(_ first: Int64, _ second: Int64) -> UploadJob {
            var one = file("a", size: 10_000, confirmed: first)
            one.id = a
            var two = file("b", size: 10_000, confirmed: second)
            two.id = b
            return job([one, two], id: id)
        }
        ledger.apply([read(0, 0)], generation: 1)
        clock.advance(10)
        ledger.apply([read(1000, 0)], generation: 2)
        clock.advance(10)
        ledger.apply([read(2000, 0)], generation: 3)
        clock.advance(10)
        // The upload session was lost and `a` starts over (OutboxPlanner, WholePlanner) while
        // `b` moves 500: the drop is not a confirmation of 2000, and does not cancel b's 500.
        ledger.apply([read(0, 500)], generation: 4)
        // 1500 bytes over 20 s = 75 B/s; 10_000 + 9_500 left: 260 s.
        #expect(ledger.estimate(at: clock.now) == .remaining(260))
    }

    @Test("a read that confirmed nothing new is not a confirmation")
    func unchangedIsNoConfirmation() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        let (id, fileID) = (UUID(), UUID())
        ledger.apply([uploading(0, id: id, fileID: fileID)], generation: 1)
        clock.advance(10)
        ledger.apply([uploading(1000, id: id, fileID: fileID)], generation: 2)
        clock.advance(10)
        ledger.apply([uploading(1000, id: id, fileID: fileID)], generation: 3)
        #expect(ledger.estimate(at: clock.now) == .unknown)
    }

    @Test("above twelve hours reads paused; exactly twelve is still a time")
    func twelveHourCeiling() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        let (id, fileID) = (UUID(), UUID())
        // 1 byte/s once measured: 43_200 bytes left is exactly 12 h.
        let size: Int64 = 2 + 43_200
        ledger.apply([uploading(0, size: size, id: id, fileID: fileID)], generation: 1)
        clock.advance(1)
        ledger.apply([uploading(1, size: size, id: id, fileID: fileID)], generation: 2)
        clock.advance(1)
        ledger.apply([uploading(2, size: size, id: id, fileID: fileID)], generation: 3)
        #expect(ledger.estimate(at: clock.now) == .remaining(TransferLedger.longestETA))
        let slower = MutableClock(start)
        let far = TransferLedger(clock: { slower.now })
        let more = size + 1
        far.apply([uploading(0, size: more, id: id, fileID: fileID)], generation: 1)
        slower.advance(1)
        far.apply([uploading(1, size: more, id: id, fileID: fileID)], generation: 2)
        slower.advance(1)
        far.apply([uploading(2, size: more, id: id, fileID: fileID)], generation: 3)
        #expect(far.estimate(at: slower.now) == .paused)
    }

    @Test("confirmations older than the window are not a rate")
    func windowTrails() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        let (id, fileID) = (UUID(), UUID())
        ledger.apply([uploading(0, id: id, fileID: fileID)], generation: 1)
        clock.advance(10)
        ledger.apply([uploading(1000, id: id, fileID: fileID)], generation: 2)
        clock.advance(10)
        ledger.apply([uploading(2000, id: id, fileID: fileID)], generation: 3)
        #expect(ledger.estimate(at: clock.now) == .remaining(80))
        #expect(
            ledger.estimate(at: clock.now.addingTimeInterval(TransferLedger.rateWindow + 1))
                == .unknown)
    }

    @Test("a queue where nothing is uploading is paused, whatever the rate was")
    func nothingUploadingIsPaused() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        let waiting = job([file("a", size: 100, confirmed: 0)], state: .waiting, wait: .noNetwork)
        ledger.apply([waiting], generation: 1)
        #expect(ledger.estimate(at: clock.now) == .paused)
    }

    @Test("bytes left only in a held capture, beside an uploading one that is done, read paused")
    func onlyHeldBytesLeftIsPaused() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        let (id, fileID) = (UUID(), UUID())
        let stuck = job(
            [file("big.mov", size: 1_000_000, confirmed: 0, uid: nil)], state: .held,
            hold: .tooLarge)
        ledger.apply([uploading(0, id: id, fileID: fileID), stuck], generation: 1)
        clock.advance(10)
        ledger.apply([uploading(5000, id: id, fileID: fileID), stuck], generation: 2)
        clock.advance(10)
        ledger.apply([uploading(10_000, id: id, fileID: fileID), stuck], generation: 3)
        // A rate was measured and a capture is still uploading, but none of the bytes left will
        // move: a time computed over nothing would read "under a minute" for a queue that waits.
        #expect(ledger.summary.bytesLeft == 1_000_000)
        #expect(ledger.estimate(at: clock.now) == .paused)
    }

    @Test("a queue with every byte confirmed has nothing left to estimate")
    func nothingLeft() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        ledger.apply([job([file("a", size: 100, confirmed: 100)], state: .creating)], generation: 1)
        #expect(ledger.estimate(at: clock.now) == .remaining(0))
    }
}

@MainActor
@Suite("Transfer ledger: the strip's lifetime")
struct TransferLedgerStripTests {
    @Test("the strip shows while a capture is queued and goes thirty seconds after the last lands")
    func lingerThirtySeconds() {
        let clock = MutableClock(start)
        let ledger = TransferLedger(clock: { clock.now })
        // Nothing queued yet, nothing ever was: no strip.
        ledger.apply([], generation: 1)
        #expect(ledger.isStripVisible(at: clock.now) == false)
        #expect(ledger.stripHidesAt == nil)
        ledger.apply([job([file("a", size: 10, confirmed: 0)])], generation: 2)
        #expect(ledger.isStripVisible(at: clock.now))
        #expect(ledger.stripHidesAt == nil)
        clock.advance(5)
        let landed = clock.now
        ledger.apply([], generation: 3)
        #expect(ledger.stripHidesAt == landed.addingTimeInterval(30))
        #expect(ledger.isStripVisible(at: landed.addingTimeInterval(29.9)))
        #expect(ledger.isStripVisible(at: landed.addingTimeInterval(30)) == false)
        // A later empty read does not restart the thirty seconds.
        clock.advance(10)
        ledger.apply([], generation: 4)
        #expect(ledger.stripHidesAt == landed.addingTimeInterval(30))
        // A new capture brings it back and ends the countdown.
        ledger.apply([job([file("b", size: 10, confirmed: 0)])], generation: 5)
        #expect(ledger.stripHidesAt == nil)
        #expect(ledger.isStripVisible(at: landed.addingTimeInterval(300)))
    }
}
