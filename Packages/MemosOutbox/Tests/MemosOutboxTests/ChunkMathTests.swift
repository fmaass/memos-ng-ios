import Foundation
import MemosOutbox
import Testing

@Suite("Chunk math")
struct ChunkMathTests {
    let chunk = 5 * 1024 * 1024

    @Test("a file is cut into whole chunks and one short last one")
    func counts() {
        #expect(ChunkMath.chunkCount(byteSize: 0, chunkSize: chunk) == 0)
        #expect(ChunkMath.chunkCount(byteSize: 1, chunkSize: chunk) == 1)
        #expect(ChunkMath.chunkCount(byteSize: Int64(chunk), chunkSize: chunk) == 1)
        #expect(ChunkMath.chunkCount(byteSize: Int64(chunk) + 1, chunkSize: chunk) == 2)
        // 5.5 MiB
        #expect(ChunkMath.chunkCount(byteSize: 5_767_168, chunkSize: chunk) == 2)
        // 700 MB video
        #expect(ChunkMath.chunkCount(byteSize: 700 * 1024 * 1024, chunkSize: chunk) == 140)
    }

    @Test("the chunk at an offset is a full chunk until the last one, which is short")
    func lengths() {
        let size = Int64(5_767_168)
        #expect(ChunkMath.chunkLength(atOffset: 0, byteSize: size, chunkSize: chunk) == chunk)
        #expect(
            ChunkMath.chunkLength(atOffset: Int64(chunk), byteSize: size, chunkSize: chunk)
                == 524_288
        )
        #expect(ChunkMath.chunkLength(atOffset: size, byteSize: size, chunkSize: chunk) == nil)
    }

    @Test("nothing is left to send for an empty file, or past the end of one")
    func edges() {
        #expect(ChunkMath.chunkLength(atOffset: 0, byteSize: 0, chunkSize: chunk) == nil)
        #expect(ChunkMath.chunkLength(atOffset: 10, byteSize: 5, chunkSize: chunk) == nil)
        #expect(ChunkMath.chunkLength(atOffset: 0, byteSize: 10, chunkSize: 0) == nil)
        #expect(ChunkMath.chunkLength(atOffset: -1, byteSize: 10, chunkSize: chunk) == nil)
        #expect(ChunkMath.chunkLength(atOffset: 0, byteSize: 1, chunkSize: chunk) == 1)
    }

    @Test("the offsets a whole file is sent at cover it exactly once")
    func offsets() {
        #expect(ChunkMath.offsets(byteSize: 0, chunkSize: 100) == [])
        #expect(ChunkMath.offsets(byteSize: 250, chunkSize: 100) == [0, 100, 200])
        #expect(ChunkMath.offsets(byteSize: 200, chunkSize: 100) == [0, 100])
        let covered = ChunkMath.offsets(byteSize: 250, chunkSize: 100)
            .compactMap { ChunkMath.chunkLength(atOffset: $0, byteSize: 250, chunkSize: 100) }
        #expect(covered.reduce(0, +) == 250)
    }
}

@Suite("Retry spacing")
struct RetryScheduleTests {
    @Test("spacing grows and then stops growing, and never gives up")
    func spacing() {
        // The transient class (MEMNG-955): 2, 4, 8, 32, 60 s, then a minute for ever.
        #expect(RetrySchedule.delay(forAttempt: 1) == 2)
        #expect(RetrySchedule.delay(forAttempt: 2) == 4)
        #expect(RetrySchedule.delay(forAttempt: 3) == 8)
        #expect(RetrySchedule.delay(forAttempt: 4) == 32)
        #expect(RetrySchedule.delay(forAttempt: 5) == 60)
        #expect(RetrySchedule.delay(forAttempt: 6) == 60)
        #expect(RetrySchedule.delay(forAttempt: 99) == 60)
        #expect(RetrySchedule.delay(forAttempt: Int.max) == 60)
    }

    @Test("a job that has failed a hundred times is still a job")
    func neverDropped() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let job = Fixture.job().backingOff(at: now, error: "no network")
        var current = job
        for _ in 0..<100 {
            current = current.backingOff(at: now, error: "no network")
        }
        #expect(current.attemptCount == 101)
        #expect(current.state == .waiting)
        #expect(current.nextAttemptAt == now.addingTimeInterval(RetrySchedule.cap))
        #expect(current.files == job.files)
    }
}
