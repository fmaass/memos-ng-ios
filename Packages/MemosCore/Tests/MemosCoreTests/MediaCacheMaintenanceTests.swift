import Foundation
import Testing

@testable import MemosCore

/// Records every call the Storage screen is able to make, so a test can assert what clearing did
/// AND what it did not do. A counter alone could only prove the first.
final class SpyCache: DerivedMediaCache {
    private(set) var calls: [String] = []
    private let disk: Int
    private let capacity: Int

    init(disk: Int, capacity: Int) {
        self.disk = disk
        self.capacity = capacity
    }

    var currentDiskUsage: Int {
        calls.append("currentDiskUsage")
        return disk
    }

    var diskCapacity: Int {
        calls.append("diskCapacity")
        return capacity
    }

    func removeAllCachedResponses() {
        calls.append("removeAllCachedResponses")
    }

    func removeCachedResponse(for request: URLRequest) {
        calls.append("removeCachedResponse(\(request.url?.absoluteString ?? "?"))")
    }
}

@Suite("Media cache size, as a person reads it")
struct MediaCacheFormattingTests {
    /// One case per input CATEGORY, because a size formatter with only a happy path is one that
    /// prints "0.0 MB" at the bottom of its range and nobody notices until it ships.
    @Test("every band of the scale has its own answer")
    func everyBand() {
        #expect(MediaCacheMaintenance.formatted(bytes: 0) == "Empty")
        // Not a size anybody has to see. A cache that reports a negative usage is a cache that
        // answered wrongly, and "Empty" is the honest reading of "there is nothing to reclaim".
        #expect(MediaCacheMaintenance.formatted(bytes: -1) == "Empty")
        #expect(MediaCacheMaintenance.formatted(bytes: 1) == "Less than 1 MB")
        #expect(MediaCacheMaintenance.formatted(bytes: 1024 * 1024 - 1) == "Less than 1 MB")
        #expect(MediaCacheMaintenance.formatted(bytes: 1024 * 1024) == "1.0 MB")
        #expect(MediaCacheMaintenance.formatted(bytes: 256 * 1024 * 1024) == "256.0 MB")
        #expect(MediaCacheMaintenance.formatted(bytes: 1024 * 1024 * 1024) == "1.0 GB")
    }

    /// The decimal is ROUNDED, not truncated: 12.46 MB shown as "12.4 MB" would be a number that
    /// disagrees with the one beside it every time the tenth rolled over.
    @Test("the tenth is rounded rather than cut off")
    func roundsTheTenth() {
        let mega = 1024 * 1024
        #expect(MediaCacheMaintenance.formatted(bytes: mega * 12 + mega * 46 / 100) == "12.5 MB")
        #expect(MediaCacheMaintenance.formatted(bytes: mega * 12 + mega * 44 / 100) == "12.4 MB")
        #expect(MediaCacheMaintenance.formatted(bytes: mega * 2 - 1) == "2.0 MB")
    }

    @Test("the row names what is held against what may be")
    func summaryNamesBoth() {
        let usage = MediaCacheMaintenance.Usage(
            usedBytes: 12 * 1024 * 1024,
            capacityBytes: 256 * 1024 * 1024
        )
        #expect(MediaCacheMaintenance.summary(usage) == "12.0 MB of 256.0 MB")
    }

    /// A button that would do nothing should not invite the tap.
    @Test("an empty cache is not clearable")
    func emptyIsNotClearable() {
        let empty = MediaCacheMaintenance.Usage(usedBytes: 0, capacityBytes: 1)
        let held = MediaCacheMaintenance.Usage(usedBytes: 1, capacityBytes: 1)
        #expect(!MediaCacheMaintenance.isClearable(empty))
        #expect(MediaCacheMaintenance.isClearable(held))
    }
}

@Suite("Clearing the derived cache")
struct MediaCacheClearingTests {
    @Test("usage is read from the cache rather than assumed")
    func usageComesFromTheCache() {
        let cache = SpyCache(disk: 4_096, capacity: 8_192)
        let usage = MediaCacheMaintenance.usage(of: cache)
        #expect(usage == MediaCacheMaintenance.Usage(usedBytes: 4_096, capacityBytes: 8_192))
    }

    /// The promise the Storage section makes is as much about what it does NOT do, so the spy
    /// records the WHOLE call log and the assertion is an equality, not a containment: clearing
    /// makes exactly one call, and it is the emptying one.
    @Test("clearing makes exactly one call, and it is the one that empties")
    func clearingCallsOnlyTheEmptier() {
        let cache = SpyCache(disk: 4_096, capacity: 8_192)
        MediaCacheMaintenance.clear(cache)
        #expect(cache.calls == ["removeAllCachedResponses"])
    }

    /// The real thing, not a spy: a response is put into a real `URLCache`, cleared, and asked for
    /// again. Remove `removeAllCachedResponses` from `clear` and this goes red — which is the only
    /// property that makes the spy above worth anything.
    @Test("a real cached response is gone afterwards")
    func aRealResponseIsRemoved() throws {
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0, diskPath: nil)
        let url = try #require(URL(string: "https://memos.example.invalid/api/attachments/a/thumb"))
        let request = URLRequest(url: url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )
        )
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: Data([0x89, 0x50, 0x4E, 0x47])),
            for: request
        )
        #expect(cache.cachedResponse(for: request) != nil)

        MediaCacheMaintenance.clear(cache)

        #expect(cache.cachedResponse(for: request) == nil)
    }

    /// The invariant the Clear button lives or dies by: a queued capture is the only copy of
    /// something somebody made, and it is not in a `URLCache`. This stands a file where the outbox
    /// keeps its own and asserts it survives — the compile-time half of the same argument being
    /// that `DerivedMediaCache` cannot name a file at all.
    @Test("a file beside the cache is untouched")
    func filesAreNotReachable() throws {
        let directory = URL.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appending(path: "job.json")
        try Data("{}".utf8).write(to: capture)

        MediaCacheMaintenance.clear(
            URLCache(memoryCapacity: 1 << 20, diskCapacity: 0, diskPath: nil)
        )

        #expect(FileManager.default.fileExists(atPath: capture.path))
    }
}
