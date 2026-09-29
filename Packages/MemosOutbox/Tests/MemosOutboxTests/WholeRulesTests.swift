import Foundation
import MemosOutbox
import Testing

/// A capture on the whole lane: a picture and a video, as the lane's own rows will look.
private enum Whole {
    static func file(
        uploadUID: String? = nil,
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

    static func job(
        files: [OutboxFile],
        state: JobState = .uploading,
        binding: AccountBinding = Fixture.binding(),
        nextAttemptAt: Date = .distantPast
    ) -> UploadJob {
        var job = Fixture.job(
            files: files, binding: binding, state: state, nextAttemptAt: nextAttemptAt
        )
        job.transport = .whole
        return job
    }

    static let now = Date(timeIntervalSince1970: 1_760_000_000)
}

@Suite("Whole lane: the transport a row records")
struct WholeTransportTests {
    /// A manifest exactly as the build before this one writes it: no `transport` anywhere.
    static let legacyManifest = """
        {"id":"6F1C1E52-2D39-4E44-9E3B-0B1F4A1D8C01",\
        "idempotencyKey":"0A3E7F5C-7B1B-4C8B-8F0E-2C4D6E8F0A12",\
        "content":"a note","capturedAt":"2025-06-15T15:06:40Z",\
        "files":[{"id":"9B2D4F60-1A3C-4E5F-8A7B-9C0D1E2F3A4B","relativePath":"file.bin",\
        "filename":"IMG_0001.HEIC","mime":"image/heic","byteSize":1024,"uploadUID":"u1",\
        "bytesConfirmed":512,"chunkSize":5242880,"uploadAttempt":2}],\
        "binding":{"serverBaseURL":"https://memos.example.invalid","ownerSubject":"fabian"},\
        "state":"uploading","attemptCount":0,"nextAttemptAt":"2025-06-15T15:06:40Z"}
        """

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    @Test("a manifest written before the lane was recorded decodes, and reads as the chunk lane")
    func legacyManifestIsChunk() throws {
        let job = try Self.decoder().decode(
            UploadJob.self, from: Data(Self.legacyManifest.utf8)
        )
        #expect(job.transport == nil)
        #expect(job.lane == .chunk)
        // The rest of the row is what it was: the lane field decoded beside it, not instead of it.
        #expect(job.files.first?.uploadUID == "u1")
        #expect(job.files.first?.bytesConfirmed == 512)
        #expect(job.files.first?.uploadAttempt == 2)
        #expect(job.state == .uploading)
    }

    @Test("a whole-lane row keeps its lane across a write, and an unstamped row writes no lane")
    func laneSurvivesTheDisk() throws {
        let whole = Whole.job(files: [Whole.file()])
        let data = try Self.encoder().encode(whole)
        let decoded = try Self.decoder().decode(UploadJob.self, from: data)
        #expect(decoded.transport == .whole)
        #expect(decoded.lane == .whole)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["transport"] as? String == "whole")

        // A row nobody stamped goes down without the key, so an older build reading it back finds
        // exactly the manifest it would have written.
        let unstamped = Fixture.job(files: [Fixture.file()])
        let plain = try Self.encoder().encode(unstamped)
        let plainObject = try #require(
            try JSONSerialization.jsonObject(with: plain) as? [String: Any]
        )
        #expect(plainObject["transport"] == nil)
        #expect(try Self.decoder().decode(UploadJob.self, from: plain).lane == .chunk)
    }
}

@Suite("Whole lane: what a capture needs next")
struct WholePlannerTests {
    let credentials = Fixture.credentials()

    func next(_ job: UploadJob, open: Bool = true) -> WholeAction {
        OutboxPlanner.nextWholeAction(
            for: job, credentials: credentials, now: Whole.now, schedulingOpen: open
        )
    }

    @Test("an unstarted capture starts every file in one pass, in capture order")
    func startsEveryFile() {
        let picture = Whole.file()
        let video = Whole.file(byteSize: 900_000)
        let job = Whole.job(files: [picture, video], state: .waiting)
        #expect(next(job) == .upload(starting: [picture.id, video.id]))
    }

    @Test("a session nothing is carrying is resumed first, before a file that has none yet")
    func retriesWhatNothingCarries() {
        let started = Whole.file(uploadUID: "p1", bytesConfirmed: 0, attempt: 1)
        let done = Whole.file(uploadUID: "v1", byteSize: 2048, bytesConfirmed: 2048)
        let fresh = Whole.file()
        let job = Whole.job(files: [started, done, fresh])
        #expect(next(job) == .resume(started.id))
        // Once the resumed file is carried, the file with no session is sent.
        #expect(
            OutboxPlanner.nextWholeAction(
                for: job, credentials: Fixture.credentials(), now: Whole.now,
                schedulingOpen: true, carried: [started.id]
            ) == .upload(starting: [fresh.id])
        )
    }

    @Test("every file on the server is a memo create")
    func completeIsCreate() {
        let job = Whole.job(files: [
            Whole.file(uploadUID: "p1", byteSize: 10, bytesConfirmed: 10),
            Whole.file(uploadUID: "v1", byteSize: 20, bytesConfirmed: 20),
        ])
        #expect(next(job) == .createMemo)
        #expect(next(Whole.job(files: [])) == .createMemo)
    }

    @Test("another account's capture is held, and never reaches a create")
    func bindingFirst() {
        let job = Whole.job(
            files: [Whole.file(uploadUID: "p1", byteSize: 10, bytesConfirmed: 10)],
            binding: Fixture.binding(owner: "someone-else")
        )
        #expect(next(job) == .hold(.accountMismatch))
        #expect(next(job, open: false) == .wait(until: .distantFuture))
    }

    @Test("a held capture stays held, a taken-back one and a backing-off one wait")
    func holdsAndWaits() {
        var held = Whole.job(files: [Whole.file()])
        held.state = .held
        held.holdReason = .storageFailed
        #expect(next(held) == .hold(.storageFailed))

        let later = Whole.now.addingTimeInterval(900)
        let backingOff = Whole.job(files: [Whole.file()], state: .waiting, nextAttemptAt: later)
        #expect(next(backingOff) == .wait(until: later))

        let complete = Whole.job(
            files: [Whole.file(uploadUID: "p1", byteSize: 10, bytesConfirmed: 10)]
        )
        let taken = complete.cancelled(at: Whole.now)
        #expect(next(taken) == .wait(until: .distantFuture))
    }

    @Test(
        "with scheduling closed the only answers are a memo create and a wait",
        arguments: ClosedGateCase.allCases
    )
    func closedGate(_ situation: ClosedGateCase) {
        let action = next(situation.job, open: false)
        switch action {
        case .createMemo, .wait:
            break
        case .hold, .upload, .resume:
            Issue.record("a closed gate answered \(action) for \(situation)")
        }
        #expect(action == situation.expectedWhenClosed)
    }

    enum ClosedGateCase: CaseIterable {
        case unstarted, retrying, complete, held, mismatched, backingOff, takenBack

        var job: UploadJob {
            switch self {
            case .unstarted:
                return Whole.job(files: [Whole.file(), Whole.file()], state: .waiting)
            case .retrying:
                return Whole.job(files: [Whole.file(uploadUID: "p1", attempt: 3)])
            case .complete:
                return Whole.job(
                    files: [Whole.file(uploadUID: "p1", byteSize: 10, bytesConfirmed: 10)]
                )
            case .held:
                var job = Whole.job(files: [Whole.file()])
                job.state = .held
                job.holdReason = .serverRefused
                return job
            case .mismatched:
                return Whole.job(
                    files: [Whole.file(uploadUID: "p1", byteSize: 10, bytesConfirmed: 10)],
                    binding: Fixture.binding(server: Fixture.otherServer)
                )
            case .backingOff:
                return Whole.job(
                    files: [Whole.file(uploadUID: "p1", byteSize: 10, bytesConfirmed: 10)],
                    state: .waiting,
                    nextAttemptAt: WholePlannerTests.later
                )
            case .takenBack:
                return Whole.job(files: [Whole.file()]).cancelled(at: Whole.now)
            }
        }

        var expectedWhenClosed: WholeAction {
            switch self {
            case .complete:
                return .createMemo
            case .backingOff:
                return .wait(until: WholePlannerTests.later)
            case .unstarted, .retrying, .held, .mismatched, .takenBack:
                return .wait(until: .distantFuture)
            }
        }
    }

    static let later = Whole.now.addingTimeInterval(3600)
}

@Suite("Whole lane: sending one file again")
struct RetryWholeTests {
    @Test(
        "a picture retried while its video is in flight: the video keeps its term and lands"
    )
    func siblingSurvivesRetry() throws {
        let launch = UUID()
        let picture = Whole.file(uploadUID: "p1", byteSize: 4096)
        let video = Whole.file(uploadUID: "v1", byteSize: 900_000)
        let job = Whole.job(files: [picture, video])
        let videoTask = WholeTaskListing(
            taskIdentifier: 2,
            taskDescription: WholeTaskIdentity(
                jobID: job.id, fileID: video.id, attempt: 0, launch: launch, epoch: 7
            ).taskDescription
        )
        let pictureTask = WholeTaskListing(
            taskIdentifier: 1,
            taskDescription: WholeTaskIdentity(
                jobID: job.id, fileID: picture.id, attempt: 0, launch: launch, epoch: 7
            ).taskDescription
        )

        // The picture's session is gone on the server.
        let answer = WholeOutcome.classify(statusCode: 404, bytesReceived: nil, byteSize: 4096)
        #expect(answer == .resume)
        let retried = job.retryingWhole(fileID: picture.id)

        // The picture goes again from nothing, under a new term.
        let movedPicture = try #require(retried.file(picture.id))
        #expect(movedPicture.uploadAttempt == 1)
        #expect(movedPicture.uploadUID == nil)
        #expect(movedPicture.bytesConfirmed == 0)
        // The video is exactly what it was — its term, its session, its bytes.
        #expect(retried.file(video.id) == video)

        // So the video's task still matches its file and is kept, while the picture's old task is
        // the one that is stale.
        let plan = WholeReconciliation.plan(jobs: [retried], tasks: [pictureTask, videoTask])
        #expect(plan.adopted.map(\.taskIdentifier) == [2])
        #expect(plan.cancelled == [1])

        // And the video's later success completes the video without touching the picture's retry.
        let videoAnswer = WholeOutcome.classify(
            statusCode: 200, bytesReceived: 900_000, byteSize: 900_000
        )
        #expect(videoAnswer == .completed(bytesReceived: 900_000))
        let landed = retried.advancing(fileID: video.id, bytesConfirmed: 900_000)
        #expect(landed.file(video.id)?.isComplete == true)
        #expect(landed.file(picture.id) == movedPicture)
        let after = OutboxPlanner.nextWholeAction(
            for: landed, credentials: Fixture.credentials(), now: Whole.now, schedulingOpen: true
        )
        #expect(after == .upload(starting: [picture.id]))
    }

    @Test("each retry is one more term, and a file already whole on the server is not sent again")
    func termsAndCompleteFiles() throws {
        let short = Whole.file(uploadUID: "p1", byteSize: 4096, bytesConfirmed: 1000, attempt: 2)
        let whole = Whole.file(uploadUID: "v1", byteSize: 10, bytesConfirmed: 10, attempt: 4)
        let job = Whole.job(files: [short, whole])

        let once = job.retryingWhole(fileID: short.id)
        #expect(once.file(short.id)?.uploadAttempt == 3)
        #expect(once.file(short.id)?.bytesConfirmed == 0)
        #expect(once.retryingWhole(fileID: short.id).file(short.id)?.uploadAttempt == 4)

        #expect(job.retryingWhole(fileID: whole.id) == job)
        #expect(job.retryingWhole(fileID: UUID()) == job)
    }
}

@Suite("Whole lane: what an answer means")
struct WholeOutcomeTests {
    func classify(_ status: Int?, _ received: Int64? = nil, size: Int64 = 1000) -> WholeOutcome {
        WholeOutcome.classify(statusCode: status, bytesReceived: received, byteSize: size)
    }

    @Test("a success that names every byte completes the file")
    func completed() {
        #expect(classify(200, 1000) == .completed(bytesReceived: 1000))
        #expect(classify(204, 1000) == .completed(bytesReceived: 1000))
        #expect(classify(299, 1200) == .completed(bytesReceived: 1200))
    }

    @Test("a success that names fewer bytes than the file resumes it")
    func shortSuccess() {
        #expect(classify(200, 999) == .resume)
        #expect(classify(200, 0) == .resume)
    }

    @Test("a success with no readable count is neither complete nor short")
    func unreadableSuccess() {
        #expect(classify(200, nil) == .unreadable)
    }

    @Test("no status at all backs off")
    func noStatus() {
        #expect(classify(nil) == .backOff)
        #expect(classify(nil, 1000) == .backOff)
    }

    @Test("a timeout backs off")
    func timeout() {
        #expect(classify(408) == .backOff)
    }

    /// A rate limit and an unavailable server say how busy the server is, not what is wrong with
    /// the file: backpressure, with no `Retry-After` to honour here.
    @Test("a rate limit and an unavailable server are backpressure", arguments: [429, 503])
    func backpressure(_ status: Int) {
        #expect(classify(status) == .backpressure(retryAfter: nil))
    }

    @Test("a server error backs off", arguments: [500, 502, 599])
    func serverError(_ status: Int) {
        #expect(classify(status) == .backOff)
    }

    @Test("a lost session resumes through the offset HEAD; an offset conflict re-syncs")
    func lostOrConflicting() {
        #expect(classify(404) == .resume)
        #expect(classify(409) == .conflict)
    }

    @Test("a file too large is a refusal")
    func tooLarge() {
        #expect(classify(413) == .refused(statusCode: 413))
    }

    @Test("an invalid request is a refusal")
    func invalid() {
        #expect(classify(422) == .refused(statusCode: 422))
    }

    @Test("every other client error is a refusal", arguments: [400, 403, 405, 410, 415, 499])
    func otherClientErrors(_ status: Int) {
        #expect(classify(status) == .refused(statusCode: status))
    }

    @Test("a status no finished transfer should carry backs off", arguments: [100, 302, 304, 600])
    func unexpected(_ status: Int) {
        #expect(classify(status) == .backOff)
    }
}

@Suite("Whole lane: a legacy row across a write")
struct WholeLegacyRoundTripTests {
    /// Compared as values, not bytes: key order and date spelling are the encoder's business, and
    /// what must survive is every field the older build wrote.
    @Test("a legacy manifest decoded and written back is the row its values describe")
    func legacyRoundTripKeepsEveryField() throws {
        let decoded = try WholeTransportTests.decoder().decode(
            UploadJob.self, from: Data(WholeTransportTests.legacyManifest.utf8)
        )
        let rewritten = try WholeTransportTests.decoder().decode(
            UploadJob.self, from: try WholeTransportTests.encoder().encode(decoded)
        )
        let instant = try #require(ISO8601DateFormatter().date(from: "2025-06-15T15:06:40Z"))
        let file = OutboxFile(
            id: try #require(UUID(uuidString: "9B2D4F60-1A3C-4E5F-8A7B-9C0D1E2F3A4B")),
            relativePath: "file.bin",
            filename: "IMG_0001.HEIC",
            mime: "image/heic",
            byteSize: 1024,
            uploadUID: "u1",
            bytesConfirmed: 512,
            chunkSize: 5_242_880,
            uploadAttempt: 2
        )
        let expected = UploadJob(
            id: try #require(UUID(uuidString: "6F1C1E52-2D39-4E44-9E3B-0B1F4A1D8C01")),
            idempotencyKey: try #require(UUID(uuidString: "0A3E7F5C-7B1B-4C8B-8F0E-2C4D6E8F0A12")),
            content: "a note",
            capturedAt: instant,
            files: [file],
            binding: AccountBinding(
                serverBaseURL: try #require(URL(string: "https://memos.example.invalid")),
                ownerSubject: "fabian"
            ),
            state: .uploading,
            attemptCount: 0,
            nextAttemptAt: instant
        )

        #expect(decoded == expected, "the legacy manifest did not decode to the values it holds")
        #expect(rewritten == expected, "a field was lost or changed by the write")
        #expect(rewritten.files == [file])
        #expect(rewritten.transport == nil, "a write stamped a lane nobody chose")
        #expect(rewritten.lane == .chunk)
    }
}

@Suite("Whole lane: the description's numeric terms")
struct WholeTaskIdentityBoundaryTests {
    /// The initializer takes any attempt; a negative one is refused where it matters, when a
    /// description is read back, so no task can be adopted under a term no manifest can hold.
    @Test("an attempt below zero does not survive the disk; an epoch below zero does")
    func numericBoundaries() {
        let jobID = UUID()
        let fileID = UUID()
        let launch = UUID()
        func identity(attempt: Int, epoch: Int) -> WholeTaskIdentity {
            WholeTaskIdentity(
                jobID: jobID, fileID: fileID, attempt: attempt, launch: launch, epoch: epoch
            )
        }

        let negativeAttempt = identity(attempt: -1, epoch: 3)
        #expect(WholeTaskIdentity(taskDescription: negativeAttempt.taskDescription) == nil)
        let zero = identity(attempt: 0, epoch: 0)
        #expect(WholeTaskIdentity(taskDescription: zero.taskDescription) == zero)
        let largest = identity(attempt: Int.max, epoch: Int.max)
        #expect(WholeTaskIdentity(taskDescription: largest.taskDescription) == largest)

        // The epoch is compared for equality and nothing else, so its sign is not checked: a
        // negative one comes back exactly as it went.
        let negativeEpoch = identity(attempt: 1, epoch: -5)
        let read = WholeTaskIdentity(taskDescription: negativeEpoch.taskDescription)
        #expect(read == negativeEpoch)
        #expect(read?.provenance(currentLaunch: launch) == .thisLaunch(epoch: -5))

        // A term too large for the platform's integer is unreadable, not wrapped.
        let big = "9223372036854775808"
        let overflow = "\(jobID.uuidString)|\(fileID.uuidString)|0|\(big)|\(launch.uuidString)|3"
        #expect(WholeTaskIdentity(taskDescription: overflow) == nil)
    }
}

@Suite("Whole lane: a retry beside a file already part-way")
struct RetryWholeSiblingBytesTests {
    @Test("a picture retried while its video holds confirmed bytes: the video's bytes are kept")
    func siblingKeepsConfirmedBytes() throws {
        let picture = Whole.file(uploadUID: "p1", byteSize: 4096, bytesConfirmed: 1024)
        let video = Whole.file(
            uploadUID: "v1", byteSize: 900_000, bytesConfirmed: 300_000, attempt: 1
        )
        let job = Whole.job(files: [picture, video])

        let retried = job.retryingWhole(fileID: picture.id)

        let keptVideo = try #require(retried.file(video.id))
        #expect(keptVideo == video)
        #expect(keptVideo.bytesConfirmed == 300_000, "the video's confirmed bytes were dropped")
        #expect(keptVideo.uploadAttempt == 1)
        #expect(keptVideo.uploadUID == "v1")
        #expect(retried.file(picture.id)?.bytesConfirmed == 0)
        #expect(retried.file(picture.id)?.uploadAttempt == 1)

        // The video's task, under its unchanged term, is still the one that carries it.
        let videoTask = WholeTaskListing(
            taskIdentifier: 2,
            taskDescription: WholeTaskIdentity(
                jobID: job.id, fileID: video.id, attempt: 1, launch: UUID(), epoch: 7
            ).taskDescription
        )
        let plan = WholeReconciliation.plan(jobs: [retried], tasks: [videoTask])
        #expect(plan.adopted.map(\.taskIdentifier) == [2])
        #expect(plan.cancelled.isEmpty)
    }
}
