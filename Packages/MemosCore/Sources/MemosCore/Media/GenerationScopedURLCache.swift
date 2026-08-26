import Foundation

/// The response cache the media layer fetches through, in which the fetch generation is part of
/// every key.
///
/// A `URLCache` files a response under the request that fetched it, and the URL loading system
/// writes into it by itself, at the moment an answer lands — which for a fetch that started
/// before a sign-out is AFTER the rotation that was supposed to have cleaned up. Nothing the
/// loader does at its own call sites can catch that write, which is why the first attempt at this
/// grew a fence per race and still had another one under it each round.
///
/// Here the write cannot land where a reader will look. Every request the media layer makes
/// carries the generation it was made under (`MediaFetchGeneration.headerField`), and the key
/// this cache stores it under is derived from the URL AND that number. A reader in generation 4
/// only ever forms generation-4 keys, so generation-3 bytes are not stale entries it might
/// prefer — they are entries it cannot name. The counter never goes backwards, so that is
/// permanent rather than a window.
///
/// A request with no generation on it is not cached at all, in either direction. That is the
/// fail-closed half, and it is deliberate: this object is also `URLCache.shared` (the app installs
/// it there), so the JSON API and anything else in the process reaches it. Filing that traffic
/// under the clock's CURRENT value would reopen exactly the race this class exists to close — the
/// write happens when the answer lands, and by then the clock has moved. Uncached is the safe
/// answer, and it costs a household-sized app a re-request of a small JSON body; the app holds its
/// domain state in its own stores rather than in a `URLCache`.
///
/// Removal is the one direction that does not fail closed: a removal that does not happen leaves
/// bytes behind, so an unstamped removal is scoped to the current generation instead of refused.
/// Dropping an entry can never serve anybody the wrong photograph.
///
/// The `@unchecked Sendable` is restated rather than inherited because the compiler requires a
/// subclass to say it again, and it is as true here as it is above: the one thing added is an
/// immutable reference to a lock-protected counter.
public final class GenerationScopedURLCache: URLCache, @unchecked Sendable {
    /// The query item the generation is carried in on the KEY url. A name nothing else would
    /// mint, so a scoped key cannot collide with a real signed URL.
    static let keyQueryItem = "__memos_fetch_generation"

    private let clock: MediaFetchGeneration

    public init(
        memoryCapacity: Int,
        diskCapacity: Int,
        diskPath: String?,
        clock: MediaFetchGeneration
    ) {
        self.clock = clock
        super.init(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: diskPath)
    }

    // MARK: - The key

    /// The entry `request` names in `generation`: the same URL with the generation appended as a
    /// query item.
    ///
    /// This URL is never fetched — it names an entry, it does not describe a request — so
    /// appending to the query cannot reach the server or disturb a signature. Appending rather
    /// than replacing keeps the map injective: two different (url, generation) pairs cannot
    /// produce one key, which is the property the whole fence rests on.
    ///
    /// `nil` when the URL cannot be taken apart at all. Refusing is the only safe answer there:
    /// falling back to the unscoped request would file the bytes exactly where the next identity
    /// looks.
    static func scopedKey(for request: URLRequest, generation: Int) -> URLRequest? {
        guard let url = request.url,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let scope = URLQueryItem(name: keyQueryItem, value: "\(generation)")
        components.queryItems = (components.queryItems ?? []) + [scope]
        guard let keyed = components.url else { return nil }
        // The request itself with its URL rewritten, rather than a fresh minimal one. What a
        // `URLCache` derives its key from is not written down anywhere this code can rely on, so
        // the only safe move is to change exactly one thing: a lookup and the store it is meant
        // to find both start from the same request and differ from it in the same single way.
        var scoped = request
        scoped.url = keyed
        return scoped
    }

    /// The key a read or a write may use: the generation the REQUEST was made under, or nothing.
    private func cachingKey(for request: URLRequest) -> URLRequest? {
        guard let generation = MediaFetchGeneration.generation(of: request) else { return nil }
        return Self.scopedKey(for: request, generation: generation)
    }

    /// The key a removal uses. Unstamped removals are scoped to the live generation rather than
    /// refused — see the class note.
    private func removalKey(for request: URLRequest) -> URLRequest? {
        let generation = MediaFetchGeneration.generation(of: request) ?? clock.current
        return Self.scopedKey(for: request, generation: generation)
    }

    private static func request(of dataTask: URLSessionDataTask) -> URLRequest? {
        dataTask.currentRequest ?? dataTask.originalRequest
    }

    // MARK: - URLCache

    public override func cachedResponse(for request: URLRequest) -> CachedURLResponse? {
        guard let key = cachingKey(for: request) else { return nil }
        return super.cachedResponse(for: key)
    }

    public override func storeCachedResponse(
        _ cachedResponse: CachedURLResponse,
        for request: URLRequest
    ) {
        guard let key = cachingKey(for: request) else { return }
        super.storeCachedResponse(cachedResponse, for: key)
    }

    public override func removeCachedResponse(for request: URLRequest) {
        guard let key = removalKey(for: request) else { return }
        super.removeCachedResponse(for: key)
    }

    /// The read `URLSession` actually performs. It is not the same method as the one above: the
    /// system asks the cache through the TASK, and a subclass that only overrode the request form
    /// would have its writes scoped and its reads unscoped — every fetch a miss, for ever.
    ///
    /// The handler is called on the caller's thread rather than hopped to a queue of ours. The
    /// work is the same disk read the synchronous method does, `URLCache` is documented as safe
    /// to use from several threads, and a hop would have to carry a non-`Sendable` cache across
    /// it.
    public override func getCachedResponse(
        for dataTask: URLSessionDataTask,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        guard let request = Self.request(of: dataTask) else {
            completionHandler(nil)
            return
        }
        completionHandler(cachedResponse(for: request))
    }

    /// The task-shaped half of the same three rules. `URLSession` caches through the task, and an
    /// override that only knew about requests would be reached or bypassed depending on which
    /// method the URL loading system happened to call — so both forms are stated, and both end at
    /// the same keyed entry.
    public override func storeCachedResponse(
        _ cachedResponse: CachedURLResponse,
        for dataTask: URLSessionDataTask
    ) {
        guard let request = Self.request(of: dataTask) else { return }
        storeCachedResponse(cachedResponse, for: request)
    }

    public override func removeCachedResponse(for dataTask: URLSessionDataTask) {
        guard let request = Self.request(of: dataTask) else { return }
        removeCachedResponse(for: request)
    }
}
