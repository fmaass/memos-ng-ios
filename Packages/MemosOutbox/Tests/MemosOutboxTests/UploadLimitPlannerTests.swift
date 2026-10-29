import Foundation
import Testing

@testable import MemosOutbox

/// The planner's size refusal (MEMNG-956), as pure vectors on both lanes.
@Suite("Planner: a staged file over the server's upload limit is held as too large")
struct UploadLimitPlannerTests {
    private static let now = Date(timeIntervalSince1970: 1000)

    private static func job(
        sizes: [Int64], transport: UploadTransport? = nil, session: String? = nil
    ) -> UploadJob {
        var job = UploadJob(
            content: "sizes", capturedAt: now,
            files: sizes.enumerated().map { index, size in
                OutboxFile(
                    relativePath: "f\(index)", filename: "f\(index).mov", mime: "video/quicktime",
                    byteSize: size)
            },
            binding: Fixture.binding(), transport: transport)
        job.nextAttemptAt = now
        if let session { job.files[0].uploadUID = session }
        return job
    }

    private static func limited(_ limit: Int64?) -> OutboxCredentials {
        var credentials = Fixture.credentials()
        credentials.uploadLimit = limit
        return credentials
    }

    private static func chunk(_ job: UploadJob, _ limit: Int64?) -> OutboxAction {
        OutboxPlanner.nextAction(for: job, credentials: limited(limit), now: now)
    }

    private static func whole(_ job: UploadJob, _ limit: Int64?, open: Bool = true) -> WholeAction {
        OutboxPlanner.nextWholeAction(
            for: job, credentials: limited(limit), now: now, schedulingOpen: open)
    }

    @Test("chunk lane: one byte over is held; at the limit, under it, or with no limit it starts")
    func chunkLaneBoundary() {
        let over = Self.job(sizes: [100, 1001])
        #expect(Self.chunk(over, 1000) == .hold(.tooLarge))
        let starting: [(Int64, Int64?)] = [(1000, 1000), (1, 1000), (1001, nil), (1001, 0)]
        for (size, limit) in starting {
            let job = Self.job(sizes: [size])
            #expect(
                Self.chunk(job, limit) == .startUpload(fileID: job.files[0].id),
                "\(size) against \(limit as Any)")
        }
    }

    @Test("whole lane: over the limit is held while scheduling is open, waits while it is closed")
    func wholeLaneBoundary() {
        let over = Self.job(sizes: [1001], transport: .whole)
        #expect(Self.whole(over, 1000) == .hold(.tooLarge))
        #expect(Self.whole(over, 1000, open: false) == .wait(until: .distantFuture))
        let fits = Self.job(sizes: [1000], transport: .whole)
        #expect(Self.whole(fits, 1000) == .upload(starting: [fits.files[0].id]))
    }

    @Test("a file the server already opened a session for is not refused for its size")
    func anAcceptedFileIsNotRefused() {
        let started = Self.job(sizes: [1001], session: "u1")
        #expect(Self.chunk(started, 1000) != .hold(.tooLarge))
        #expect(OutboxPlanner.oversizedFile(in: started, limit: 1000) == nil)
    }

    @Test("the hold's reason names both sizes; any other hold keeps its own sentence")
    func theMessageNamesBothSizes() throws {
        let over = Self.job(sizes: [1_600_000_000])
        let message = try #require(
            OutboxPlanner.holdMessage(
                for: .tooLarge, of: over, credentials: Self.limited(1_000_000_000)))
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        #expect(message.contains(format(1_600_000_000)))
        #expect(message.contains(format(1_000_000_000)))
        #expect(
            OutboxPlanner.holdMessage(
                for: .serverRefused, of: over, credentials: Self.limited(1_000_000_000)) == nil)
        #expect(
            OutboxPlanner.holdMessage(for: .tooLarge, of: over, credentials: Self.limited(nil))
                == nil)
    }
}
