import Foundation
import MemosOutbox
import Testing

/// A capture Post took while some of its files were still loading (MEMNG-951).
///
/// The files that were there go to the queue at once; the rest are appended as they land, and the
/// create waits for the editor to let the capture go. Every case drives the real repository on a
/// real directory — the fence an append must lose to a release is a read and a write inside that
/// actor, and a double would be asserting the test's own idea of it.
@MainActor
@Suite("A capture whose files are still arriving")
struct StagingTests {
    private struct Harness {
        let root: URL
        let repository: OutboxRepository
        let http: ScriptedHTTP
        let outbox: Outbox
        let scheduler: ScriptedScheduler
        let preferencesName: String

        var memoPosts: [URLRequest] {
            http.requests(method: "POST").filter { $0.url?.path() == "/api/memos" }
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            Fixture.forgetting(preferencesName)
        }
    }

    private func harness() throws -> Harness {
        let root = try Fixture.temporaryDirectory()
        let provider = SwitchableCredentials(Fixture.credentials())
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { provider.stillCurrent(epoch: $0) }
        )
        let memos = MemoCounter()
        let http = ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/memos"):
                return ScriptedHTTP.json(["uid": memos.next()], status: 201)
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
        let preferences = Fixture.preferences(allowsMobileData: true)
        let box = AttemptHandlerBox()
        let scheduler = ScriptedScheduler()
        let outbox = Outbox(
            repository: repository,
            credentials: provider,
            http: http,
            scheduler: scheduler,
            completion: MemoCompletionEndpoint(http: http),
            network: StubNetworkPath(),
            preferences: preferences.store,
            attachScheduler: { handler in box.value = handler }
        )
        return Harness(
            root: root, repository: repository, http: http, outbox: outbox, scheduler: scheduler,
            preferencesName: preferences.name
        )
    }

    private func source(_ harness: Harness, _ name: String, bytes: Int = 64) throws -> StagedSource
    {
        let url = try Fixture.file(in: harness.root, named: name, bytes: bytes)
        return StagedSource(url: url, filename: name, mime: "image/heic")
    }

    // MARK: - the planners

    @Test("a capture whose files are all up waits for the editor instead of being created")
    func plannersHoldTheCreateWhileFilesArrive() {
        var job = Fixture.job(files: [Fixture.file(uploadUID: "u1", bytesConfirmed: 1024)])
        job.stagingLaunch = UUID()
        let credentials = Fixture.credentials()
        let chunk = OutboxPlanner.nextAction(for: job, credentials: credentials, now: Date())
        #expect(chunk == .wait(until: .distantFuture))
        let whole = OutboxPlanner.nextWholeAction(
            for: job, credentials: credentials, now: Date(), schedulingOpen: true
        )
        #expect(whole == .wait(until: .distantFuture))

        job.stagingLaunch = nil
        let released = OutboxPlanner.nextAction(for: job, credentials: credentials, now: Date())
        #expect(released == .createMemo)
        #expect(
            OutboxPlanner.nextWholeAction(
                for: job, credentials: credentials, now: Date(), schedulingOpen: true
            ) == .createMemo)
    }

    @Test("a file already here uploads while the others are still arriving")
    func filesHereUploadMeanwhile() {
        var job = Fixture.job(files: [Fixture.file()])
        job.stagingLaunch = UUID()
        let whole = OutboxPlanner.nextWholeAction(
            for: job, credentials: Fixture.credentials(), now: Date(), schedulingOpen: true
        )
        #expect(whole == .upload(starting: job.files.map(\.id)))
    }

    // MARK: - append and release

    @Test("a late file joins the capture; after the release nothing more is taken")
    func appendUntilReleased() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let launch = UUID()
        let job = try await harness.repository.enqueue(
            content: "beach", visibility: "PRIVATE", capturedAt: Date(),
            binding: Fixture.binding(), sources: [try source(harness, "a.heic")],
            stagingLaunch: launch
        )
        let late = try source(harness, "b.heic", bytes: 80)
        let appended = try await harness.repository.append([late], to: job.id, arrivingFrom: launch)
        #expect(appended?.files.map(\.filename) == ["a.heic", "b.heic"])
        let stored = try #require(appended?.files.last)
        let copy = harness.repository.mediaURL(job: try #require(appended), file: stored)
        #expect(try Data(contentsOf: copy) == Fixture.content(80))

        // Another launch's editor is not this capture's.
        let foreign = try await harness.repository.append(
            [try source(harness, "c.heic")], to: job.id, arrivingFrom: UUID())
        #expect(foreign == nil)

        let release = try await harness.repository.releaseStaging(job.id, arrivingFrom: launch)
        #expect(release == .released)
        let afterRelease = try await harness.repository.append(
            [try source(harness, "d.heic")], to: job.id, arrivingFrom: launch)
        #expect(afterRelease == nil)
        let onDisk = try #require(await harness.repository.job(job.id))
        #expect(onDisk.files.map(\.filename) == ["a.heic", "b.heic"])
        #expect(onDisk.stagingLaunch == nil)
    }

    @Test("a late file that cannot be read leaves every file the capture held where it was")
    func unreadableLateFileLosesNothing() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let launch = UUID()
        let job = try await harness.repository.enqueue(
            content: "", visibility: nil, capturedAt: Date(), binding: Fixture.binding(),
            sources: [try source(harness, "a.heic")], stagingLaunch: launch
        )
        let gone = StagedSource(
            url: harness.root.appending(path: "never-written.heic"), filename: "x.heic",
            mime: "image/heic")
        let readable = try source(harness, "b.heic")
        var threw = false
        do {
            _ = try await harness.repository.append(
                [readable, gone], to: job.id, arrivingFrom: launch)
        } catch is OutboxStorageError {
            threw = true
        }
        #expect(threw)
        let onDisk = try #require(await harness.repository.job(job.id))
        #expect(onDisk.files == job.files)
        #expect(onDisk.stagingLaunch == launch)
        // The copy of the file that DID read is not left behind for the sweep to puzzle over.
        let held = try #require(job.files.first)
        let directory = harness.repository.mediaURL(job: job, file: held)
            .deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path())
        #expect(names.count == 1)
        // And the capture is still let go: its create is not held back for ever.
        let release = try await harness.repository.releaseStaging(job.id, arrivingFrom: launch)
        #expect(release == .released)
    }

    @Test("a capture that ends with no words and no files is removed, not created")
    func emptyCaptureIsRemovedOnRelease() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let launch = UUID()
        let job = try await harness.repository.enqueue(
            content: "  \n", visibility: nil, capturedAt: Date(), binding: Fixture.binding(),
            sources: [], stagingLaunch: launch
        )
        let release = try await harness.repository.releaseStaging(job.id, arrivingFrom: launch)
        #expect(release == .emptied)
        #expect(await harness.repository.job(job.id) == nil)
    }

    @Test("adoption lets go of a capture a dead launch's editor was still filling, and no other")
    func adoptionReleasesOnlyForeignStaging() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let dead = try await harness.repository.enqueue(
            content: "from before", visibility: nil, capturedAt: Date(),
            binding: Fixture.binding(), sources: [], stagingLaunch: UUID()
        )
        let live = try await harness.repository.enqueue(
            content: "this launch", visibility: nil, capturedAt: Date(),
            binding: Fixture.binding(), sources: [],
            stagingLaunch: OutboxUploadSession.processLaunch
        )
        let released = try await harness.repository.releaseStaging(
            leftOverBefore: OutboxUploadSession.processLaunch)
        #expect(released == [dead.id])
        #expect(await harness.repository.job(dead.id)?.stagingLaunch == nil)
        #expect(await harness.repository.job(live.id)?.stagingLaunch != nil)
    }

    // MARK: - the facade

    @Test("a staged capture is not created until it is released, and then exactly once")
    func stagedCaptureWaitsForRelease() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let id = try #require(
            await harness.outbox.stage(
                content: "words", visibility: "PRIVATE", sources: [try source(harness, "a.heic")]
            ))
        await harness.outbox.start()
        await harness.outbox.drain()
        #expect(harness.memoPosts.isEmpty)
        #expect(harness.outbox.jobs.map(\.id) == [id])

        #expect(await harness.outbox.append([try source(harness, "b.heic")], to: id))
        await harness.outbox.release(id)
        // A late file after the release is refused, never added under a create's key.
        #expect(await !harness.outbox.append([try source(harness, "c.heic")], to: id))
        await harness.outbox.drain()
        #expect(harness.outbox.jobs.first?.files.map(\.filename) == ["a.heic", "b.heic"])
        #expect(harness.outbox.jobs.first?.stillArriving == false)
    }

    @Test("the memo a capture became is named by its job once the job has left the queue")
    func resolvedMemoIsNamedByJob() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let id = try #require(
            await harness.outbox.stage(content: "words only", visibility: "PRIVATE", sources: []))
        await harness.outbox.start()
        await harness.outbox.release(id)
        // Until the job is gone or the passes run out: a drain that joins one already running
        // returns with its own pass, and the create is the next one (as `RecoveryTests.settle`).
        for _ in 0..<6 {
            if await harness.repository.job(id) == nil { break }
            await harness.outbox.drain()
            try await Task.sleep(for: .milliseconds(20))
        }
        await harness.outbox.refresh()
        #expect(harness.memoPosts.count == 1)
        #expect(harness.outbox.jobs.isEmpty)
        #expect(harness.outbox.resolvedMemos[id] == "m1")
    }

    @Test("Remove takes a capture that has not been sent out of the queue")
    func withdrawRemovesAnUnsentCapture() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let id = try #require(
            await harness.outbox.stage(content: "never mind", visibility: nil, sources: []))
        #expect(await harness.outbox.withdraw(id))
        #expect(await harness.repository.job(id) == nil)
        #expect(harness.outbox.jobs.isEmpty)
        // Its editor's late files have nowhere to go now, and the release finds nothing.
        #expect(await !harness.outbox.append([try source(harness, "a.heic")], to: id))
    }

    @Test("Remove is refused once the create has been claimed, and the capture is untouched")
    func withdrawRefusedOnceCreateClaimed() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let enqueued = try await harness.repository.enqueue(
            content: "on the wire", visibility: nil, capturedAt: Date(),
            binding: Fixture.binding(), sources: []
        )
        // The row as persisted: the fence compares with the disk, not with the value offered.
        let job = try #require(await harness.repository.job(enqueued.id))
        // The pass's claim, written as the engine writes it before the request goes out.
        let creating = try #require(
            try await harness.repository.save(
                job.creatingMemo(), ifStillCurrent: nil, matching: job, else: job.creatingMemo()))
        #expect(await !harness.outbox.withdraw(job.id))
        #expect(await harness.repository.job(job.id) == creating)
    }

    @Test("Remove that loses its delete to a write in its hop says so, and the row stays")
    func withdrawLosingItsDeleteIsRefused() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let enqueued = try await harness.repository.enqueue(
            content: "two hands", visibility: nil, capturedAt: Date(),
            binding: Fixture.binding(), sources: []
        )
        let id = enqueued.id
        // Inside the hop between Remove's cancelled mark and its delete, another write lands on
        // the row — a Cancel of the same capture a minute on, written through the same fence as
        // `Outbox.cancel` writes it. The row on disk is no longer the one Remove marked.
        let repository = harness.repository
        let competing = LockedBox<UploadJob?>(nil)
        harness.scheduler.beforeInFlight = {
            guard let row = await repository.job(id), let marked = row.cancelledAt else { return }
            let later = row.cancelled(at: marked.addingTimeInterval(60))
            competing.value =
                (try? await repository.save(later, ifStillCurrent: nil, matching: row, else: later))
                ?? nil
        }
        #expect(await !harness.outbox.withdraw(id))
        let written = try #require(competing.value, "the competing write never landed")
        #expect(await harness.repository.job(id) == written)
        #expect(harness.outbox.jobs.map(\.id) == [id])
    }

    @Test("Cancel is refused while files still arrive; once let go the capture comes back whole")
    func cancelRefusedWhileFilesArrive() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let id = try #require(
            await harness.outbox.stage(
                content: "beach", visibility: nil, sources: [try source(harness, "a.heic")]))
        let before = try #require(await harness.repository.job(id))
        #expect(await harness.outbox.cancel(id) == nil)
        #expect(await harness.repository.job(id) == before)
        // The late file still has its capture to go to.
        #expect(await harness.outbox.append([try source(harness, "b.heic")], to: id))
        await harness.outbox.release(id)
        let draft = try #require(await harness.outbox.cancel(id))
        #expect(draft.pictures.map(\.filename) == ["a.heic", "b.heic"])
    }

    @Test("a late item that failed to copy, or never came by the release, counts as missing")
    func missedItemsAreCountedOnTheCapture() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let id = try #require(
            await harness.outbox.stage(
                content: "beach", visibility: nil, sources: [try source(harness, "a.heic")],
                arriving: 3))
        #expect(await harness.repository.job(id)?.notArrived == 3)
        #expect(await harness.outbox.append([try source(harness, "b.heic")], to: id))
        let gone = StagedSource(
            url: harness.root.appending(path: "never-written.heic"), filename: "x.heic",
            mime: "image/heic")
        #expect(await !harness.outbox.append([gone], to: id))
        // Still arriving: nothing is missing YET, whatever the count says.
        let staged = try #require(await harness.repository.job(id))
        #expect(staged.notArrived == 2)
        #expect(staged.missingItems == 0)
        // The limit: the third never answered. It and the one that failed are what is missing.
        await harness.outbox.release(id)
        let released = try #require(await harness.repository.job(id))
        #expect(released.files.map(\.filename) == ["a.heic", "b.heic"])
        #expect(released.missingItems == 2)
        // A refused late append changes nothing about what the capture says.
        #expect(await !harness.outbox.append([try source(harness, "c.heic")], to: id))
        #expect(await harness.repository.job(id)?.missingItems == 2)
    }

    @Test("a capture whose editor died is let go naming what never came")
    func deadEditorsItemsAreCounted() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let job = try await harness.repository.enqueue(
            content: "beach", visibility: nil, capturedAt: Date(), binding: Fixture.binding(),
            sources: [try source(harness, "a.heic")], stagingLaunch: UUID(), arriving: 2
        )
        _ = try await harness.repository.releaseStaging(leftOverBefore: UUID())
        #expect(await harness.repository.job(job.id)?.missingItems == 2)
    }

    @Test("a Post whose every picked item failed is kept, stopped, to say so")
    func emptyCaptureWithMissedItemsIsKept() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let launch = UUID()
        let job = try await harness.repository.enqueue(
            content: "", visibility: nil, capturedAt: Date(), binding: Fixture.binding(),
            sources: [], stagingLaunch: launch, arriving: 1
        )
        let release = try await harness.repository.releaseStaging(job.id, arrivingFrom: launch)
        #expect(release == .stoppedEmpty)
        let kept = try #require(await harness.repository.job(job.id))
        #expect(kept.cancelledAt != nil)
        #expect(kept.missingItems == 1)
    }

    @Test("a kept capture with nothing in it is never handed back nor sent again")
    func nothingToSendIsNeverResubmitted() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let id = try #require(
            await harness.outbox.stage(content: "", visibility: nil, sources: [], arriving: 1))
        await harness.outbox.release(id)
        let kept = try #require(await harness.repository.job(id))
        #expect(kept.hasNothingToSend)
        // Cancel refuses it (MEMNG-1049): an empty draft is a re-post the queue would refuse.
        #expect(await harness.outbox.cancel(id) == nil)
        #expect(await harness.repository.job(id) == kept)
        // And whatever an editor hands back for it, the re-post is refused all the same.
        let draft = RestoredDraft(
            jobID: id, content: "", visibility: nil, capturedAt: kept.capturedAt, pictures: [])
        #expect(await harness.outbox.resubmit(id, draft: draft) == .refused(.nothingToSend))
        #expect(await harness.repository.job(id) == kept)
        #expect(harness.memoPosts.isEmpty)
    }

    @Test("a release the disk refused leaves the capture arriving; the next one lets it go once")
    func releaseThatFailedToPersistIsTakenLater() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let id = try #require(
            await harness.outbox.stage(
                content: "dunes", visibility: nil, sources: [try source(harness, "a.heic")],
                arriving: 1))
        let staged = try #require(await harness.repository.job(id))
        let restore = try Fixture.permissions(
            0o500, on: harness.root.appending(path: "outbox").appending(path: "jobs"))
        await harness.outbox.release(id)
        restore()
        // Nothing half-written: the capture is exactly as it was, still taking files, its create
        // still held, and the late file still has somewhere to go.
        #expect(await harness.repository.job(id) == staged)
        #expect(harness.outbox.jobs.first?.stillArriving == true)
        #expect(harness.memoPosts.isEmpty)
        #expect(await harness.outbox.append([try source(harness, "b.heic")], to: id))
        // Recovery in the same launch: the next release is taken, once.
        await harness.outbox.release(id)
        let released = try #require(await harness.repository.job(id))
        #expect(!released.stillArriving)
        #expect(released.files.map(\.filename) == ["a.heic", "b.heic"])
        #expect(released.missingItems == 0)
        #expect(await !harness.outbox.append([try source(harness, "c.heic")], to: id))
    }

    @Test("a re-post clears what the card said had not arrived")
    func resubmitClearsTheMissingCount() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let id = try #require(
            await harness.outbox.stage(
                content: "beach", visibility: nil, sources: [try source(harness, "a.heic")],
                arriving: 1))
        await harness.outbox.release(id)
        #expect(await harness.repository.job(id)?.missingItems == 1)
        let draft = try #require(await harness.outbox.cancel(id))
        #expect(await harness.outbox.resubmit(id, draft: draft) == .accepted)
        let reposted = try #require(await harness.repository.job(id))
        #expect(reposted.notArrived == nil)
        #expect(reposted.missingItems == 0)
    }

    @Test("a manifest written before the count decodes as nothing missing")
    func manifestWithoutCountDecodes() throws {
        var job = Fixture.job(files: [])
        job.notArrived = 2
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        #expect(object.removeValue(forKey: "notArrived") != nil)
        let old = try JSONDecoder().decode(
            UploadJob.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.notArrived == nil)
        #expect(old.missingItems == 0)
    }

    @Test("a create that went out once without an answer may have made the memo")
    func createMayHaveBeenSentAfterAnUnansweredAttempt() {
        let up = Fixture.file(uploadUID: "u1", bytesConfirmed: 1024)
        #expect(!Fixture.job(files: [up]).createMayHaveBeenSent)
        #expect(Fixture.job(files: [up]).creatingMemo().createMayHaveBeenSent)
        let backedOff = Fixture.job(files: [up]).backingOff(at: Date(), error: "timeout")
        #expect(backedOff.createMayHaveBeenSent)
        // An upload that failed with a file still missing never reached the create.
        let uploading = Fixture.job(files: [Fixture.file()]).backingOff(at: Date(), error: "x")
        #expect(!uploading.createMayHaveBeenSent)
    }
}

/// Hands out m1, m2, … to successive creates.
private final class MemoCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> String {
        lock.withLock {
            count += 1
            return "m\(count)"
        }
    }
}

/// What a write a case put inside a hop landed as, read back once the hop is over.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
