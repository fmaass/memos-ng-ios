import Foundation
import MemosOutbox
import Testing

@Suite("What a job needs next")
struct PlannerTests {
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("a file with no upload session gets one first")
    func startsUploads() {
        let file = Fixture.file()
        let job = Fixture.job(files: [file])
        #expect(
            OutboxPlanner.nextAction(for: job, credentials: Fixture.credentials(), now: now)
                == .startUpload(fileID: file.id)
        )
    }

    @Test("a started file is sent from the offset the server confirmed")
    func sendsChunks() {
        let file = Fixture.file(
            uploadUID: "u1", byteSize: 2500, bytesConfirmed: 1000, chunkSize: 1000
        )
        let job = Fixture.job(files: [file])
        #expect(
            OutboxPlanner.nextAction(for: job, credentials: Fixture.credentials(), now: now)
                == .uploadChunk(fileID: file.id, offset: 1000, length: 1000)
        )
    }

    @Test("the last chunk is short, and then the memo is created")
    func lastChunkThenCreate() {
        var file = Fixture.file(
            uploadUID: "u1", byteSize: 2500, bytesConfirmed: 2000, chunkSize: 1000
        )
        let job = Fixture.job(files: [file])
        #expect(
            OutboxPlanner.nextAction(for: job, credentials: Fixture.credentials(), now: now)
                == .uploadChunk(fileID: file.id, offset: 2000, length: 500)
        )
        file.bytesConfirmed = 2500
        let finished = Fixture.job(files: [file])
        #expect(
            OutboxPlanner.nextAction(for: finished, credentials: Fixture.credentials(), now: now)
                == .createMemo
        )
    }

    @Test("a note with no media goes straight to the memo")
    func textOnly() {
        let job = Fixture.job(files: [])
        #expect(
            OutboxPlanner.nextAction(for: job, credentials: Fixture.credentials(), now: now)
                == .createMemo
        )
        #expect(job.fractionUploaded == 1)
    }

    @Test("a job spacing out a retry waits, and says until when")
    func waits() {
        let job = Fixture.job(files: [], nextAttemptAt: now.addingTimeInterval(600))
        #expect(
            OutboxPlanner.nextAction(for: job, credentials: Fixture.credentials(), now: now)
                == .wait(until: now.addingTimeInterval(600))
        )
    }

    @Test("a job captured under another account is held, whatever else is true of it")
    func binding() {
        let job = Fixture.job(files: [Fixture.file()])
        let otherPerson = Fixture.credentials(owner: "someone-else")
        let otherServer = Fixture.credentials(server: Fixture.otherServer)
        #expect(
            OutboxPlanner.nextAction(for: job, credentials: otherPerson, now: now)
                == .hold(.accountMismatch)
        )
        #expect(
            OutboxPlanner.nextAction(for: job, credentials: otherServer, now: now)
                == .hold(.accountMismatch)
        )
        #expect(job.binding.matches(Fixture.credentials()))
    }

    @Test("a held job is never picked up by a timer")
    func heldStaysHeld() {
        let job = Fixture.job(files: [Fixture.file()]).held(.serverRefused, error: "no")
        #expect(
            OutboxPlanner.nextAction(for: job, credentials: Fixture.credentials(), now: now)
                == .hold(.serverRefused)
        )
    }
}

@Suite("Job transitions")
struct TransitionTests {
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("an upload session's answer decides the chunk size and the starting offset")
    func startingUpload() {
        let file = Fixture.file(byteSize: 3000, chunkSize: 5 * 1024 * 1024)
        let job = Fixture.job(files: [file])
        let resumed = job.startingUpload(
            fileID: file.id,
            session: OutboxWire.UploadSession(uploadUID: "u1", chunkSize: 1000, bytesReceived: 500)
        )
        #expect(resumed.file(file.id)?.uploadUID == "u1")
        #expect(resumed.file(file.id)?.chunkSize == 1000)
        #expect(resumed.file(file.id)?.bytesConfirmed == 500)
        #expect(resumed.state == .uploading)
    }

    @Test("the cursor only ever moves to a number the server gave, and never past the file")
    func advancing() {
        let file = Fixture.file(uploadUID: "u1", byteSize: 3000)
        let job = Fixture.job(files: [file]).backingOff(at: now, error: "flaky")
        let advanced = job.advancing(fileID: file.id, bytesConfirmed: 9999)
        #expect(advanced.file(file.id)?.bytesConfirmed == 3000)
        #expect(advanced.attemptCount == 0)
        #expect(advanced.lastError == nil)
        let rewound = advanced.advancing(fileID: file.id, bytesConfirmed: 1000)
        #expect(rewound.file(file.id)?.bytesConfirmed == 1000)
    }

    @Test("a lost upload session forgets the uid and the cursor, and keeps the original")
    func lostUpload() {
        let file = Fixture.file(uploadUID: "u1", byteSize: 3000, bytesConfirmed: 2000)
        let job = Fixture.job(files: [file])
        let cleared = job.clearingLostUpload(fileID: file.id)
        #expect(cleared.file(file.id)?.uploadUID == nil)
        #expect(cleared.file(file.id)?.bytesConfirmed == 0)
        #expect(cleared.file(file.id)?.relativePath == file.relativePath)
        #expect(cleared.files.count == 1)
    }

    @Test("releasing a held job clears the hold and lets it run now")
    func release() {
        let job = Fixture.job(files: []).held(.accountMismatch, error: "other account")
        let released = job.released(at: now)
        #expect(released.state == .waiting)
        #expect(released.holdReason == nil)
        #expect(released.nextAttemptAt == now)
    }
}

@Suite("Unlinkable recovery")
struct UnlinkableTests {
    @Test("the structured refusal decodes exactly, and nothing else does")
    func decoding() throws {
        let body = Data(
            """
            {"detail":{"code":"uploads_unlinkable","missing_upload_uids":["a"],\
            "incomplete_upload_uids":["b","c"]}}
            """.utf8)
        let failure = try #require(UploadsUnlinkableFailure.decode(body))
        #expect(failure.missingUploadUIDs == ["a"])
        #expect(failure.incompleteUploadUIDs == ["b", "c"])

        // A validation error is NOT upload loss: reading it as one would re-upload files that
        // were never lost.
        let validation = Data(#"{"detail":[{"loc":["body","content"],"msg":"required"}]}"#.utf8)
        #expect(UploadsUnlinkableFailure.decode(validation) == nil)
        let otherCode = Data(#"{"detail":{"code":"something_else"}}"#.utf8)
        #expect(UploadsUnlinkableFailure.decode(otherCode) == nil)
        #expect(UploadsUnlinkableFailure.decode(Data("not json".utf8)) == nil)
    }

    @Test("a missing uid restarts its file; an incomplete one re-syncs it")
    func recovery() {
        let missing = Fixture.file(uploadUID: "a", byteSize: 100, bytesConfirmed: 100)
        let incomplete = Fixture.file(uploadUID: "b", byteSize: 100, bytesConfirmed: 100)
        let fine = Fixture.file(uploadUID: "c", byteSize: 100, bytesConfirmed: 100)
        let job = Fixture.job(files: [missing, incomplete, fine])
        let plan = OutboxPlanner.recovery(
            for: job,
            failure: UploadsUnlinkableFailure(
                missingUploadUIDs: ["a"], incompleteUploadUIDs: ["b"]
            )
        )
        #expect(plan.restart == [missing.id])
        #expect(plan.resync == [incomplete.id])

        let applied = job.applying(plan)
        #expect(applied.file(missing.id)?.uploadUID == nil)
        #expect(applied.file(missing.id)?.bytesConfirmed == 0)
        #expect(applied.file(incomplete.id)?.uploadUID == "b")
        #expect(applied.file(fine.id)?.uploadUID == "c")
        #expect(applied.files.count == 3)
    }

    @Test("a uid the job does not carry is ignored rather than guessed at")
    func unknownUID() {
        let job = Fixture.job(files: [Fixture.file(uploadUID: "a")])
        let plan = OutboxPlanner.recovery(
            for: job,
            failure: UploadsUnlinkableFailure(
                missingUploadUIDs: ["zzz"], incompleteUploadUIDs: []
            )
        )
        #expect(plan.isEmpty)
    }
}
