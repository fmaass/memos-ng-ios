import Foundation
import Testing

@testable import MemosCore

/// The seam MEMNG-135 is closed at, asserted directly.
///
/// Each of the first three tests is one of the races the previous attempt's review rounds found,
/// written in the order that made it a defect. They are not three fixes here: they are three
/// consequences of one property — a stale writer and a live reader cannot name the same entry.
@Suite("The generation-scoped response cache")
struct GenerationScopedURLCacheTests {
    private func makeCache(_ clock: MediaFetchGeneration) -> GenerationScopedURLCache {
        // Memory-only: a disk-backed cache writes asynchronously, and a seed-then-read against
        // one is a timing test wearing a correctness test's clothes.
        GenerationScopedURLCache(
            memoryCapacity: 4 * 1024 * 1024,
            diskCapacity: 0,
            diskPath: nil,
            clock: clock
        )
    }

    /// The shape the server mints, signature and all — so the key derivation is exercised against
    /// a URL that already has a query rather than a bare path.
    private func signed(_ uid: String) throws -> URL {
        try #require(
            URL(
                string: "https://memos.example.invalid/api/attachments/\(uid)/thumb"
                    + "?exp=4000000000&scope=1&sig=aaaa"
            )
        )
    }

    private func entry(_ url: URL, bytes: [UInt8]) throws -> CachedURLResponse {
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )
        )
        return CachedURLResponse(response: response, data: Data(bytes))
    }

    private func request(_ url: URL, generation: Int) -> URLRequest {
        MediaFetchGeneration.stamped(URLRequest(url: url), generation: generation)
    }

    /// The cost side of the ledger: an identity that has not changed keeps every byte it fetched.
    @Test("an entry stored in one generation is answered in the same generation")
    func theSameGenerationIsAHit() throws {
        let cache = makeCache(MediaFetchGeneration())
        let url = try signed("hit")
        let stored = try entry(url, bytes: [0x89, 0x50, 0x4E, 0x47])

        cache.storeCachedResponse(stored, for: request(url, generation: 0))

        let answered = try #require(cache.cachedResponse(for: request(url, generation: 0)))
        #expect(answered.data == stored.data)
    }

    /// The fence itself. Note what is asserted about the OLD stamp: the entry is still there. It
    /// was not purged and then raced — it simply has a name the next identity never forms.
    @Test("an entry from a previous generation cannot be named by the next one")
    func aRotationMakesEntriesUnnameable() throws {
        let cache = makeCache(MediaFetchGeneration())
        let url = try signed("rotated")
        let stored = try entry(url, bytes: [0x01, 0x02, 0x03])

        cache.storeCachedResponse(stored, for: request(url, generation: 0))

        #expect(cache.cachedResponse(for: request(url, generation: 1)) == nil)
        #expect(cache.cachedResponse(for: request(url, generation: 0)) != nil)
    }

    /// Round three's race: the stale writer lands AFTER the live one, for the same URL.
    ///
    /// With one key per URL this was unwinnable — the late write either replaced the live entry or
    /// the fence evicted the live entry trying to prevent it. Two keys, and neither happens.
    @Test("a stale answer landing after a live one does not replace it")
    func aStaleWriteCannotLandOnALiveEntry() throws {
        let cache = makeCache(MediaFetchGeneration())
        let url = try signed("reverse")
        let live = try entry(url, bytes: [0xAA, 0xBB])
        let stale = try entry(url, bytes: [0xCC, 0xDD])

        cache.storeCachedResponse(live, for: request(url, generation: 1))
        // The previous identity's fetch, which was on the wire across the rotation, lands now.
        cache.storeCachedResponse(stale, for: request(url, generation: 0))

        let answered = try #require(cache.cachedResponse(for: request(url, generation: 1)))
        #expect(answered.data == live.data, "the previous identity's bytes replaced the live ones")
    }

    /// Round two's race, which was the fence hurting the account it existed to protect: a removal
    /// aimed at the previous identity's bytes took the live identity's entry for the same URL.
    @Test("a removal for a previous generation leaves the live entry alone")
    func aStaleRemovalCannotEvictTheLiveEntry() throws {
        let cache = makeCache(MediaFetchGeneration())
        let url = try signed("removal")
        let live = try entry(url, bytes: [0x11, 0x22])

        cache.storeCachedResponse(live, for: request(url, generation: 1))
        cache.removeCachedResponse(for: request(url, generation: 0))

        #expect(cache.cachedResponse(for: request(url, generation: 1)) != nil)
    }

    /// The fail-closed half. This object is also `URLCache.shared`, so traffic that is not the
    /// media layer's reaches it — and traffic that cannot say which identity it belongs to is not
    /// cached rather than filed under a guess.
    @Test("a request with no generation on it is not cached at all")
    func anUnstampedRequestIsNotCached() throws {
        let cache = makeCache(MediaFetchGeneration())
        let url = try signed("unstamped")
        let stored = try entry(url, bytes: [0x30, 0x31])

        cache.storeCachedResponse(stored, for: URLRequest(url: url))

        #expect(cache.cachedResponse(for: URLRequest(url: url)) == nil)
        #expect(cache.cachedResponse(for: request(url, generation: 0)) == nil)
    }

    /// Removal is the one direction that does not fail closed, and this is why it matters: the
    /// lapsed-signature eviction (`MediaCache.evictExpired`) names the entry by URL alone. A
    /// removal that quietly did nothing would leave an entry whose signature no longer verifies
    /// being served out of the cache.
    @Test("an unstamped removal drops the live generation's entry")
    func anUnstampedRemovalScopesToTheLiveGeneration() throws {
        let clock = MediaFetchGeneration()
        clock.rotate()
        let cache = makeCache(clock)
        let url = try signed("lapsed")
        let stored = try entry(url, bytes: [0x40, 0x41])

        cache.storeCachedResponse(stored, for: request(url, generation: clock.current))
        #expect(cache.cachedResponse(for: request(url, generation: clock.current)) != nil)

        let longAfterTheSignature = Date(timeIntervalSince1970: 5_000_000_000)
        #expect(MediaCache.evictExpired(url, at: longAfterTheSignature, cache: cache))

        #expect(cache.cachedResponse(for: request(url, generation: clock.current)) == nil)
    }

    /// What the Storage screen's Clear and the rotation's reclamation both call, still emptying
    /// everything regardless of which generation stored it.
    @Test("emptying the cache reaches every generation in it")
    func emptyingReachesEveryGeneration() throws {
        let cache = makeCache(MediaFetchGeneration())
        let url = try signed("cleared")
        let stored = try entry(url, bytes: [0x50])

        cache.storeCachedResponse(stored, for: request(url, generation: 0))
        cache.storeCachedResponse(stored, for: request(url, generation: 1))

        MediaCacheMaintenance.clear(cache)

        #expect(cache.cachedResponse(for: request(url, generation: 0)) == nil)
        #expect(cache.cachedResponse(for: request(url, generation: 1)) == nil)
    }
}

/// A stub that answers any request with a cacheable image, and says how many times it was asked.
///
/// It answers rather than hits: a custom protocol is asked to LOAD, and serving a hit out of the
/// cache is the protocol's own job, which the HTTP protocol does and a stub does not. So the count
/// says how many requests reached the protocol layer, and what the cache did with the answers is
/// asserted against the cache itself.
final class StubMediaLedger: @unchecked Sendable {
    static let shared = StubMediaLedger()

    private let lock = NSLock()
    private var served: [URL] = []

    func record(_ url: URL) {
        lock.lock()
        served.append(url)
        lock.unlock()
    }

    func count(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return served.filter { $0 == url }.count
    }
}

final class StubMediaProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "image/png",
                    "Cache-Control": "private, max-age=600",
                ]
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        StubMediaLedger.shared.record(url)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Data([0x89, 0x50, 0x4E, 0x47]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The seam through the REAL URL loading system, which is the half no unit test of the cache can
/// reach.
///
/// `URLSession` caches what it fetched by itself, through the `URLCache` its configuration holds,
/// on whichever thread the answer arrived on. Everything above is written in the belief that that
/// write goes through this subclass — and a belief is not a fence. If the system stored under the
/// plain request instead, the entry it left behind would be reachable by the identity that follows,
/// and this suite would say so.
@Suite("The media cache through URLSession", .serialized)
struct GenerationScopedURLCacheThroughURLSessionTests {
    @Test("a fetch is cached under its own generation and not the next one's")
    func aFetchIsCachedUnderItsOwnGeneration() async throws {
        let clock = MediaFetchGeneration()
        let cache = GenerationScopedURLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 0,
            diskPath: nil,
            clock: clock
        )
        let configuration = MediaCache.makeSessionConfiguration(cache: cache)
        configuration.protocolClasses = [StubMediaProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        // A URL nothing else in the process has fetched, so the counts below are this test's.
        let url = try #require(
            URL(string: "https://memos.example.invalid/api/attachments/\(UUID().uuidString)/thumb")
        )
        let underTheFirstIdentity = MediaFetchGeneration.stamped(
            URLRequest(url: url),
            generation: clock.current
        )

        _ = try await session.data(for: underTheFirstIdentity)
        #expect(StubMediaLedger.shared.count(for: url) == 1)

        // The system's own write, landing at a key this test can name only because the subclass
        // put it there. Polled because that write is not synchronous with the answer.
        var cached = false
        for _ in 0..<40 where !cached {
            cached = cache.cachedResponse(for: underTheFirstIdentity) != nil
            if !cached { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(cached, "URLSession's own write did not go through the generation-scoped key")

        // The device is somebody else now. Those bytes — written by the system itself, on its own
        // thread, after this test stopped being able to intervene — cannot be named by the
        // identity that follows, nor by anything that does not say which identity it is.
        clock.rotate()
        let underTheSecondIdentity = MediaFetchGeneration.stamped(
            URLRequest(url: url),
            generation: clock.current
        )
        #expect(cache.cachedResponse(for: underTheSecondIdentity) == nil)
        #expect(cache.cachedResponse(for: URLRequest(url: url)) == nil)
    }

    /// What the system does on the READ side, exercised through the method it uses for a data
    /// task rather than through a session.
    ///
    /// It cannot be observed through the session above, and the reason is a property of the
    /// harness rather than of the cache: a custom `URLProtocol` is asked to load, and serving a
    /// hit is the protocol's own job — the HTTP protocol does it, a stub does not, and no cache
    /// read happens above either of them. So the read is called here directly, in the task shape
    /// `URLSession` uses, which is the surface that has to answer.
    @Test("the task-shaped read answers the live generation and nothing else")
    func theTaskShapedReadIsScopedToo() async throws {
        let clock = MediaFetchGeneration()
        let cache = GenerationScopedURLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 0,
            diskPath: nil,
            clock: clock
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let url = try #require(
            URL(string: "https://memos.example.invalid/api/attachments/\(UUID().uuidString)/thumb")
        )
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )
        )
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let underTheFirstIdentity = MediaFetchGeneration.stamped(
            URLRequest(url: url),
            generation: clock.current
        )
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: bytes),
            for: underTheFirstIdentity
        )

        let answered = await read(underTheFirstIdentity, from: cache, through: session)
        #expect(answered == bytes, "the task-shaped read did not find the task-shaped write")

        clock.rotate()
        let underTheSecondIdentity = MediaFetchGeneration.stamped(
            URLRequest(url: url),
            generation: clock.current
        )

        let afterTheRotation = await read(underTheSecondIdentity, from: cache, through: session)
        #expect(afterTheRotation == nil)
    }

    /// The task-shaped read, awaited. Only the bytes cross back out: `CachedURLResponse` is not
    /// `Sendable`, and the bytes are the whole question anyway.
    private func read(
        _ request: URLRequest,
        from cache: GenerationScopedURLCache,
        through session: URLSession
    ) async -> Data? {
        let task = session.dataTask(with: request)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            cache.getCachedResponse(for: task) { continuation.resume(returning: $0?.data) }
        }
    }
}
