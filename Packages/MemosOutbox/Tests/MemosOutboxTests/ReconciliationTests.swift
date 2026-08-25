import Foundation
import MemosOutbox
import Testing

@Suite("Relaunch reconciliation")
struct ReconciliationTests {
    @Test("a task identity survives the process as a string, and garbage does not decode")
    func identityRoundTrip() throws {
        let identity = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 5_242_880)
        let decoded = try #require(
            OutboxTaskIdentity(taskDescription: identity.taskDescription)
        )
        #expect(decoded == identity)
        #expect(OutboxTaskIdentity(taskDescription: nil) == nil)
        #expect(OutboxTaskIdentity(taskDescription: "") == nil)
        #expect(OutboxTaskIdentity(taskDescription: "a|b|c") == nil)
        #expect(OutboxTaskIdentity(taskDescription: "\(UUID())|\(UUID())|-1") == nil)
        #expect(OutboxTaskIdentity(taskDescription: "\(UUID())|\(UUID())") == nil)
    }

    @Test("a surviving task that still fits its job is adopted, and the job is NOT re-scheduled")
    func adoptsMatchingTask() {
        let file = Fixture.file(uploadUID: "u1", byteSize: 3000, bytesConfirmed: 1000)
        let job = Fixture.job(files: [file], state: .uploading)
        let task = OutboxTaskIdentity(jobID: job.id, fileID: file.id, offset: 1000)

        let plan = OutboxReconciliation.plan(jobs: [job], inFlight: [task])
        #expect(plan.adopted == [task])
        #expect(plan.cancelled.isEmpty)
        #expect(plan.drainable.isEmpty)
    }

    @Test("a task at an offset the job has moved past is cancelled and the job drains again")
    func cancelsStaleTask() {
        let file = Fixture.file(uploadUID: "u1", byteSize: 3000, bytesConfirmed: 2000)
        let job = Fixture.job(files: [file], state: .uploading)
        let stale = OutboxTaskIdentity(jobID: job.id, fileID: file.id, offset: 1000)

        let plan = OutboxReconciliation.plan(jobs: [job], inFlight: [stale])
        #expect(plan.adopted.isEmpty)
        #expect(plan.cancelled == [stale])
        #expect(plan.drainable == [job.id])
    }

    @Test("two tasks for one job never both survive")
    func neverTwoTasksForOneJob() {
        let file = Fixture.file(uploadUID: "u1", byteSize: 3000, bytesConfirmed: 1000)
        let job = Fixture.job(files: [file], state: .uploading)
        let first = OutboxTaskIdentity(jobID: job.id, fileID: file.id, offset: 1000)
        let second = OutboxTaskIdentity(jobID: job.id, fileID: file.id, offset: 1000)

        let plan = OutboxReconciliation.plan(jobs: [job], inFlight: [first, second])
        #expect(plan.adopted.count == 1)
        #expect(plan.cancelled.count == 1)
        #expect(plan.drainable.isEmpty)
    }

    @Test("the same job id arriving twice is planned, not died on")
    func duplicateJobIDsArePlannedOnce() {
        let file = Fixture.file(uploadUID: "u1", byteSize: 3000, bytesConfirmed: 1000)
        let job = Fixture.job(files: [file], state: .uploading)
        // What a capture set aside under one id more than once used to hand this: two entries,
        // one id. It runs on the launch path, so dying here loses the whole queue, not one row.
        let plan = OutboxReconciliation.plan(
            jobs: [job, job],
            inFlight: [OutboxTaskIdentity(jobID: job.id, fileID: file.id, offset: 1000)]
        )
        #expect(plan.adopted.count == 1)
        #expect(plan.cancelled.isEmpty)
        #expect(plan.drainable.isEmpty)

        let waiting = Fixture.job(files: [Fixture.file(byteSize: 10)], state: .waiting)
        let idle = OutboxReconciliation.plan(jobs: [waiting, waiting], inFlight: [])
        #expect(
            idle.drainable == [waiting.id],
            "one id is one job to drain — twice would be two uploads of the same bytes"
        )
    }

    @Test("a task whose job is gone, held, or already complete is cancelled")
    func cancelsOrphans() {
        let done = Fixture.file(uploadUID: "u1", byteSize: 3000, bytesConfirmed: 3000)
        let finished = Fixture.job(files: [done], state: .creating)
        let held = Fixture.job(
            files: [Fixture.file(uploadUID: "u2", byteSize: 3000, bytesConfirmed: 0)]
        ).held(.accountMismatch, error: "other account")

        let ghost = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 0)
        let onFinished = OutboxTaskIdentity(jobID: finished.id, fileID: done.id, offset: 3000)
        let onHeld = OutboxTaskIdentity(
            jobID: held.id, fileID: held.files[0].id, offset: 0
        )

        let plan = OutboxReconciliation.plan(
            jobs: [finished, held], inFlight: [ghost, onFinished, onHeld]
        )
        #expect(plan.adopted.isEmpty)
        #expect(Set(plan.cancelled) == Set([ghost, onFinished, onHeld]))
        #expect(plan.drainable == [finished.id, held.id])
    }

    /// The session no longer decides which network a capture goes over — the engine does, before
    /// each request, against the path as it is at that instant. A session that refused cellular
    /// itself could never be told otherwise: its configuration is fixed for the lifetime of the
    /// process, so a toggle turned on this afternoon would hold every chunk until a force-quit.
    /// Constrained stays refused here too: Low Data Mode is not the toggle's to override.
    @Test("a background session leaves the network decision to the engine, except Low Data Mode")
    func backgroundConfiguration() {
        let configuration = OutboxSession.backgroundConfiguration(appGroup: "group.test.invalid")
        #expect(configuration.identifier == "live.discomarder.memosng.outbox")
        #expect(configuration.sharedContainerIdentifier == "group.test.invalid")
        #expect(configuration.allowsCellularAccess == true)
        #expect(configuration.allowsExpensiveNetworkAccess == true)
        #expect(configuration.allowsConstrainedNetworkAccess == false)
        #expect(configuration.isDiscretionary == false)
        #expect(configuration.sessionSendsLaunchEvents == true)
        #expect(OutboxSession.identifier == "live.discomarder.memosng.outbox")
    }

    @MainActor
    @Test("the system's background completion handler is fired once and then forgotten")
    func backgroundCompletion() {
        let completion = OutboxBackgroundCompletion()
        var fired = 0
        completion.store { fired += 1 }
        #expect(completion.isPending)
        completion.fire()
        completion.fire()
        #expect(fired == 1)
        #expect(!completion.isPending)
    }
}

@Suite("Queue progress")
struct ProgressTests {
    @Test("a job that left the queue is a memo the server confirmed")
    func detectsCompletion() {
        let first = UUID()
        let second = UUID()
        #expect(OutboxProgress.didComplete(previous: [first, second], current: [second]))
        #expect(!OutboxProgress.didComplete(previous: [first], current: [first]))
        #expect(!OutboxProgress.didComplete(previous: [], current: [first]))
        #expect(!OutboxProgress.didComplete(previous: [first], current: [first, second]))
    }
}
