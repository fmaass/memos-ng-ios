import Foundation
import Testing

@testable import MemosOutbox

private func wholeJob(
    files count: Int, now: Date = Date(timeIntervalSince1970: 1000)
) -> UploadJob {
    UploadJob(
        content: "five files",
        capturedAt: now,
        files: (0..<count).map { index in
            OutboxFile(
                relativePath: "f\(index)", filename: "f\(index).heic", mime: "image/heic",
                byteSize: 100
            )
        },
        binding: Fixture.binding(),
        transport: .whole
    )
}

@Suite("Whole lane: the upload budget and per-file spacing, as pure rules")
struct UploadBudgetTests {
    @Test("a five-file capture with nothing carried starts exactly two files, in capture order")
    func fiveFilesStartTwo() throws {
        let job = wholeJob(files: 5)
        let action = OutboxPlanner.nextWholeAction(
            for: job, credentials: Fixture.credentials(), now: job.capturedAt,
            schedulingOpen: true, carried: []
        )
        #expect(action == .upload(starting: [job.files[0].id, job.files[1].id], retrying: []))
    }

    @Test("with two of its files carried, a five-file capture starts none")
    func twoCarriedStartNone() throws {
        let job = wholeJob(files: 5)
        let action = OutboxPlanner.nextWholeAction(
            for: job, credentials: Fixture.credentials(), now: job.capturedAt,
            schedulingOpen: true, carried: [job.files[0].id, job.files[1].id]
        )
        #expect(action == .upload(starting: [], retrying: []))
    }

    @Test("a file waiting out its deadline takes no place: the next eligible files go instead")
    func deadlineBeforeBudget() throws {
        var job = wholeJob(files: 3)
        job.files[0].nextAttemptAt = job.capturedAt.addingTimeInterval(60)
        let action = OutboxPlanner.nextWholeAction(
            for: job, credentials: Fixture.credentials(), now: job.capturedAt,
            schedulingOpen: true
        )
        #expect(action == .upload(starting: [job.files[1].id, job.files[2].id], retrying: []))
        job.files[1].nextAttemptAt = job.capturedAt.addingTimeInterval(30)
        job.files[2].nextAttemptAt = job.capturedAt.addingTimeInterval(90)
        let waiting = OutboxPlanner.nextWholeAction(
            for: job, credentials: Fixture.credentials(), now: job.capturedAt,
            schedulingOpen: true
        )
        #expect(waiting == .wait(until: job.capturedAt.addingTimeInterval(30)))
    }

    @Test("the jitter is exact under the injected draw: 0, half, and the whole computed delay")
    func jitterIsExact() {
        #expect(RetrySchedule.delay(forAttempt: 1, retryAfter: nil, rng: { 0 }) == 0)
        #expect(RetrySchedule.delay(forAttempt: 1, retryAfter: nil, rng: { 0.5 }) == 450)
        #expect(RetrySchedule.delay(forAttempt: 1, retryAfter: nil, rng: { 1 }) == 900)
        #expect(RetrySchedule.delay(forAttempt: 3, retryAfter: nil, rng: { 0.5 }) == 1800)
        #expect(RetrySchedule.delay(forAttempt: 3, retryAfter: nil, rng: { 1 }) == 3600)
        // The existing curve every other caller uses is unchanged.
        #expect(RetrySchedule.delay(forAttempt: 1) == 900)
        #expect(RetrySchedule.delay(forAttempt: 3) == 3600)
    }

    @Test("a Retry-After replaces the computed delay, un-jittered, whatever the draw")
    func retryAfterReplaces() {
        for draw in [0.0, 0.5, 1.0] {
            #expect(RetrySchedule.delay(forAttempt: 4, retryAfter: 2, rng: { draw }) == 2)
        }
        // The cap bounds the computed curve only: a server's longer delay is taken as named.
        #expect(RetrySchedule.cap < 86_400)
        #expect(RetrySchedule.delay(forAttempt: 1, retryAfter: 86_400, rng: { 1 }) == 86_400)
    }

    @Test("a Retry-After past seven days is ignored like an HTTP-date; seven days is kept")
    func retryAfterBound() throws {
        #expect(UploadBudget.longestRetryAfter == 604_800)
        #expect(WholeOutcome.seconds(inRetryAfter: "604800") == 604_800)
        #expect(WholeOutcome.seconds(inRetryAfter: "604801") == nil)
        #expect(WholeOutcome.seconds(inRetryAfter: String(Int.max)) == nil)
        #expect(WholeOutcome.seconds(inRetryAfter: "99999999999999999999") == nil)
        func deadline(after header: String) throws -> Date? {
            var job = wholeJob(files: 1)
            job.files[0].uploadUID = "u1"
            let retry = FileRetry(
                retryAfter: WholeOutcome.seconds(inRetryAfter: header), draw: 0.5
            )
            return try #require(
                job.applyingFileAnswer(
                    fileID: job.files[0].id, attempt: 0, change: .backOff("busy", retry),
                    stillCurrent: true, at: Date(timeIntervalSince1970: 1000)
                )
            ).files[0].nextAttemptAt
        }
        #expect(try deadline(after: "604800") == Date(timeIntervalSince1970: 1000 + 604_800))
        // Ignored: the first attempt's computed delay, half of 900 s under the draw.
        #expect(try deadline(after: "604801") == Date(timeIntervalSince1970: 1450))
        #expect(try deadline(after: String(Int.max)) == Date(timeIntervalSince1970: 1450))
    }

    @Test("429 and 503 are backpressure with the header's seconds; an HTTP-date is ignored")
    func backpressureClassifies() {
        func classify(_ status: Int, _ header: String?) -> WholeOutcome {
            WholeOutcome.classify(
                statusCode: status, bytesReceived: nil, byteSize: 10, retryAfter: header
            )
        }
        #expect(classify(429, "2") == .backpressure(retryAfter: 2))
        #expect(classify(503, " 120 ") == .backpressure(retryAfter: 120))
        #expect(classify(429, "Wed, 21 Oct 2026 07:28:00 GMT") == .backpressure(retryAfter: nil))
        #expect(classify(503, nil) == .backpressure(retryAfter: nil))
        #expect(classify(408, "2") == .backOff)
        #expect(classify(500, "2") == .backOff)
    }

    @Test("a sibling's success keeps a file's own deadline and count")
    func siblingSuccessKeepsDeadline() throws {
        var job = wholeJob(files: 2)
        job.files = job.files.map { file in
            var sent = file
            sent.uploadUID = "u-\(file.filename)"
            return sent
        }
        let busy = try #require(
            job.applyingFileAnswer(
                fileID: job.files[1].id, attempt: 0,
                change: .backOff("busy", FileRetry(retryAfter: 2, draw: 1)),
                stillCurrent: true, at: Date(timeIntervalSince1970: 1000)
            )
        )
        let confirmed = try #require(
            busy.applyingFileAnswer(
                fileID: job.files[0].id, attempt: 0, change: .confirmed(100),
                stillCurrent: true, at: Date(timeIntervalSince1970: 1001)
            )
        )
        #expect(confirmed.files[1].nextAttemptAt == Date(timeIntervalSince1970: 1002))
        #expect(confirmed.files[1].attemptCount == 1)
        #expect(confirmed.files[0].nextAttemptAt == nil)
    }

    @Test("a short success takes the file's schedule instead of sending again at once")
    func shortSuccessTakesSchedule() throws {
        var job = wholeJob(files: 1)
        job.files[0].uploadUID = "u1"
        let outcome = WholeOutcome.classify(statusCode: 204, bytesReceived: 40, byteSize: 100)
        #expect(outcome == .retryWhole)
        let next = try #require(
            job.applyingFileAnswer(
                fileID: job.files[0].id, attempt: 0, change: .retryWhole(FileRetry(draw: 0.5)),
                stillCurrent: true, at: Date(timeIntervalSince1970: 1000)
            )
        )
        #expect(next.files[0].uploadUID == nil)
        #expect(next.files[0].nextAttemptAt == Date(timeIntervalSince1970: 1450))
        let action = OutboxPlanner.nextWholeAction(
            for: next, credentials: Fixture.credentials(),
            now: Date(timeIntervalSince1970: 1001), schedulingOpen: true
        )
        #expect(action == .wait(until: Date(timeIntervalSince1970: 1450)))
    }

    @Test("a fractional instant's deadline is rounded up to the whole second a manifest keeps")
    func deadlineRoundsUp() throws {
        let job = wholeJob(files: 1)
        let next = job.backingOffFile(
            job.files[0].id, retry: FileRetry(retryAfter: 2, draw: 0),
            error: "busy", at: Date(timeIntervalSince1970: 1000.75)
        )
        #expect(next.files[0].nextAttemptAt == Date(timeIntervalSince1970: 1003))
    }

    @Test("the background configuration allows the budget's connections per host and no more")
    func connectionCap() {
        let configuration = OutboxUploadSession.backgroundConfiguration(
            appGroup: "group.test.invalid"
        )
        #expect(configuration.httpMaximumConnectionsPerHost == 2)
        #expect(UploadBudget.inFlightUploads == 2)
    }
}
