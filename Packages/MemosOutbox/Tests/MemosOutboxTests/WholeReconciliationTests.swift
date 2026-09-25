import Foundation
import MemosOutbox
import Testing

private enum Matrix {
    static let launch = UUID()

    static func file(
        uploadUID: String? = "u1",
        byteSize: Int64 = 4096,
        bytesConfirmed: Int64 = 0,
        attempt: Int? = nil
    ) -> OutboxFile {
        var file = Fixture.file(
            uploadUID: uploadUID, byteSize: byteSize, bytesConfirmed: bytesConfirmed
        )
        file.uploadAttempt = attempt
        return file
    }

    static func job(_ files: [OutboxFile]) -> UploadJob {
        var job = Fixture.job(files: files, state: .uploading)
        job.transport = .whole
        return job
    }

    static func task(
        _ identifier: Int, _ job: UploadJob, _ file: OutboxFile, attempt: Int = 0
    ) -> WholeTaskListing {
        WholeTaskListing(
            taskIdentifier: identifier,
            taskDescription: WholeTaskIdentity(
                jobID: job.id, fileID: file.id, attempt: attempt, launch: launch, epoch: 3
            ).taskDescription
        )
    }
}

@Suite("Whole lane: the task description")
struct WholeTaskIdentityTests {
    @Test("six terms go out and come back as the same identity")
    func roundTrip() throws {
        let identity = WholeTaskIdentity(
            jobID: UUID(), fileID: UUID(), attempt: 2, launch: UUID(), epoch: 41
        )
        let terms = identity.taskDescription.split(separator: "|").map(String.init)
        #expect(
            terms == [
                identity.jobID.uuidString, identity.fileID.uuidString, "0", "2",
                identity.launch.uuidString, "41",
            ]
        )
        #expect(WholeTaskIdentity(taskDescription: identity.taskDescription) == identity)
    }

    @Test("a task from this launch carries its epoch, and one from another launch carries none")
    func provenance() throws {
        let here = UUID()
        let identity = WholeTaskIdentity(
            jobID: UUID(), fileID: UUID(), attempt: 0, launch: here, epoch: 5
        )
        let parsed = try #require(WholeTaskIdentity(taskDescription: identity.taskDescription))
        #expect(parsed.provenance(currentLaunch: here) == .thisLaunch(epoch: 5))
        #expect(parsed.provenance(currentLaunch: UUID()) == .unknown)
    }

    @Test("anything this lane did not write does not parse, a chunk description included")
    func unreadable() {
        let job = UUID().uuidString
        let file = UUID().uuidString
        let launch = UUID().uuidString
        let descriptions: [String?] = [
            nil, "", "a|b|c|d|e|f",
            "\(job)|\(file)|0|1",
            "\(job)|\(file)|4096|1|\(launch)|3",
            "\(job)|\(file)|0|-1|\(launch)|3",
            "\(job)|\(file)|0|1|not-a-launch|3",
            "\(job)|\(file)|0|1|\(launch)|",
            "\(job)|\(file)|0|1|\(launch)|3|extra",
        ]
        for description in descriptions {
            #expect(WholeTaskIdentity(taskDescription: description) == nil)
        }
        // And the chunk lane never reads a whole task as one of its own.
        let whole = WholeTaskIdentity(
            jobID: UUID(), fileID: UUID(), attempt: 0, launch: UUID(), epoch: 1
        )
        #expect(OutboxTaskIdentity(taskDescription: whole.taskDescription) == nil)
    }
}

@Suite("Whole lane: the relaunch matrix")
struct WholeReconciliationTests {
    @Test("task and record match: adopted, and the file is not sent again")
    func matchingIsAdopted() {
        let file = Matrix.file()
        let job = Matrix.job([file])
        let task = Matrix.task(9, job, file)

        let plan = WholeReconciliation.plan(jobs: [job], tasks: [task])
        #expect(plan.adopted.map(\.taskIdentifier) == [9])
        #expect(plan.adopted.first?.identity.fileID == file.id)
        #expect(plan.cancelled.isEmpty)
        #expect(plan.retryWhole.isEmpty)
    }

    @Test("two tasks for one capture's two files are both adopted")
    func twoFilesTwoTasks() {
        let picture = Matrix.file(uploadUID: "p1")
        let video = Matrix.file(uploadUID: "v1", byteSize: 900_000, attempt: 2)
        let job = Matrix.job([picture, video])
        let tasks = [Matrix.task(1, job, picture), Matrix.task(2, job, video, attempt: 2)]

        let plan = WholeReconciliation.plan(jobs: [job], tasks: tasks)
        #expect(plan.adopted.map(\.taskIdentifier) == [1, 2])
        #expect(plan.cancelled.isEmpty)
        #expect(plan.retryWhole.isEmpty)
    }

    @Test("a second task for the same file is the duplicate, and is cancelled")
    func oneTaskPerFile() {
        let file = Matrix.file()
        let job = Matrix.job([file])

        let plan = WholeReconciliation.plan(
            jobs: [job], tasks: [Matrix.task(1, job, file), Matrix.task(2, job, file)]
        )
        #expect(plan.adopted.map(\.taskIdentifier) == [1])
        #expect(plan.cancelled == [2])
    }

    @Test("a task with nothing to carry is cancelled", arguments: TaskOnly.allCases)
    func taskOnlyIsCancelled(_ reason: TaskOnly) {
        let file = Matrix.file(attempt: 1)
        let (jobs, task) = reason.situation(file: file)

        let plan = WholeReconciliation.plan(jobs: jobs, tasks: [task])
        #expect(plan.adopted.isEmpty)
        #expect(plan.cancelled == [task.taskIdentifier])
    }

    enum TaskOnly: CaseIterable {
        case noJob, held, takenBack, attemptMismatch, chunkRow, fileComplete, noSession

        func situation(file: OutboxFile) -> (jobs: [UploadJob], task: WholeTaskListing) {
            var job = Matrix.job([file])
            var sent = file
            var attempt = 1
            switch self {
            case .noJob:
                return ([], Matrix.task(4, job, file, attempt: 1))
            case .held:
                job.state = .held
                job.holdReason = .serverRefused
            case .takenBack:
                job = job.cancelled(at: Date(timeIntervalSince1970: 1_760_000_000))
            case .attemptMismatch:
                attempt = 0
            case .chunkRow:
                job.transport = nil
            case .fileComplete:
                sent.bytesConfirmed = sent.byteSize
                job.files = [sent]
            case .noSession:
                sent.uploadUID = nil
                job.files = [sent]
            }
            return ([job], Matrix.task(4, job, file, attempt: attempt))
        }
    }

    @Test("a task whose description cannot be read is marked for cancel, not dropped")
    func unreadableIsCancelled() {
        let job = Matrix.job([Matrix.file()])
        let tasks = [
            WholeTaskListing(taskIdentifier: 7, taskDescription: nil),
            WholeTaskListing(taskIdentifier: 8, taskDescription: "garbage"),
        ]

        let plan = WholeReconciliation.plan(jobs: [job], tasks: tasks)
        #expect(plan.adopted.isEmpty)
        #expect(plan.cancelled == [7, 8])
    }

    @Test("a session no task is carrying is sent again whole, and only on the whole lane")
    func recordOnlyIsRetried() {
        let carried = Matrix.file(uploadUID: "p1")
        let orphan = Matrix.file(uploadUID: "v1", bytesConfirmed: 100, attempt: 1)
        let job = Matrix.job([carried, orphan])
        var chunkRow = Fixture.job(files: [Matrix.file()], state: .uploading)
        chunkRow.transport = .chunk
        var held = Matrix.job([Matrix.file()])
        held.state = .held
        let takenBack = Matrix.job([Matrix.file()]).cancelled(at: Date())

        let plan = WholeReconciliation.plan(
            jobs: [job, chunkRow, held, takenBack], tasks: [Matrix.task(1, job, carried)]
        )
        #expect(plan.adopted.map(\.taskIdentifier) == [1])
        #expect(plan.retryWhole == [WholeFileRef(jobID: job.id, fileID: orphan.id)])
    }

    @Test("neither a task nor a session to carry: nothing to do")
    func neither() {
        let unstarted = Matrix.file(uploadUID: nil)
        let done = Matrix.file(uploadUID: "v1", byteSize: 10, bytesConfirmed: 10)
        let job = Matrix.job([unstarted, done])

        let plan = WholeReconciliation.plan(jobs: [job], tasks: [])
        #expect(plan == WholeReconciliationPlan(adopted: [], cancelled: [], retryWhole: []))
    }

    @Test("the same capture listed twice is planned once")
    func duplicateJobIDs() {
        let file = Matrix.file()
        let job = Matrix.job([file])

        let plan = WholeReconciliation.plan(jobs: [job, job], tasks: [])
        #expect(plan.retryWhole == [WholeFileRef(jobID: job.id, fileID: file.id)])
    }
}

@Suite("Whole lane: a cancelled task leaves its file to be sent again")
struct WholeStrandedRecordTests {
    @Test("a task naming a file its capture no longer has is cancelled")
    func missingFileIsCancelled() {
        let kept = Matrix.file()
        let job = Matrix.job([kept])
        let gone = Matrix.file()
        let task = Matrix.task(4, job, gone)

        let plan = WholeReconciliation.plan(jobs: [job], tasks: [task])
        #expect(plan.adopted.isEmpty)
        #expect(plan.cancelled == [4])
        #expect(plan.retryWhole == [WholeFileRef(jobID: job.id, fileID: kept.id)])
    }

    @Test("a task under a superseded term is cancelled, and its file is sent again")
    func attemptMismatchRetries() {
        let file = Matrix.file(attempt: 1)
        let job = Matrix.job([file])
        let stale = Matrix.task(4, job, file, attempt: 0)

        let plan = WholeReconciliation.plan(jobs: [job], tasks: [stale])
        #expect(plan.adopted.isEmpty)
        #expect(plan.cancelled == [4])
        #expect(plan.retryWhole == [WholeFileRef(jobID: job.id, fileID: file.id)])
    }

    @Test("an unreadable task is cancelled, and the file nothing carries is sent again")
    func unreadableLeavesTheRecordToRetry() {
        let file = Matrix.file()
        let job = Matrix.job([file])
        let tasks = [WholeTaskListing(taskIdentifier: 8, taskDescription: "garbage")]

        let plan = WholeReconciliation.plan(jobs: [job], tasks: tasks)
        #expect(plan.adopted.isEmpty)
        #expect(plan.cancelled == [8])
        #expect(plan.retryWhole == [WholeFileRef(jobID: job.id, fileID: file.id)])
    }
}
