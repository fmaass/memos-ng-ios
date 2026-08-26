import Foundation

/// A derived-media URL carrying the server's HMAC signature and its expiry.
///
/// memos-ng serves renditions through signed URLs with an `exp`, so a cache entry that outlives
/// `exp` is worse than useless: it keeps showing an image the app can no longer re-fetch, and it
/// hides the moment the signature stopped working. Everything here exists to bound a cached
/// response to the signature that authorised it.
public struct SignedMediaURL: Sendable, Equatable {
    public let url: URL
    /// `nil` when the URL carries no `exp` — an unsigned URL, which is never cached longer than
    /// the server's own headers allow.
    public let expiresAt: Date?

    public init(url: URL) {
        self.url = url
        self.expiresAt = Self.parseExpiry(from: url)
    }

    static func parseExpiry(from url: URL) -> Date? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let item = components.queryItems?.first(where: { $0.name == "exp" }),
            let value = item.value, let seconds = TimeInterval(value)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// How much life a signature must have left for the fetch it authorises to be worth starting.
    ///
    /// `exp` is a deadline, not a promise about the request that reads it: a URL with seconds on
    /// it is refused halfway through the fetch it was minted for, and what the reader sees is a
    /// broken picture that a freshly signed URL would have shown. A minute covers a request on a
    /// slow connection, and it can never be the reason a re-read happens on a URL somebody could
    /// still have used: the server mints these with at least an hour of life
    /// (`bucketed_exp` in memos-ng `app/services/asset_urls.py` rounds the mint time down to a
    /// one-hour bucket and adds a two-hour TTL).
    public static let horizon: TimeInterval = 60

    /// Whether this signature is spent for a fetch STARTING at `now` — `exp` already past, or
    /// close enough to it that the fetch would not finish inside it.
    ///
    /// `horizon` is a parameter and not only a constant because it is what makes the rule
    /// assertable: a test says which side of the boundary it is on instead of waiting for one.
    public func isPastHorizon(
        at now: Date,
        horizon: TimeInterval = SignedMediaURL.horizon
    ) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= horizon
    }

    /// The same question with no margin at all: is the signature already refused. Expressed
    /// through `isPastHorizon` so the two answers cannot drift apart.
    public func isExpired(at now: Date) -> Bool {
        isPastHorizon(at: now, horizon: 0)
    }

    /// Seconds this response may still be served from cache. Never negative, never beyond `exp`.
    public func remainingLifetime(at now: Date) -> TimeInterval? {
        guard let expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSince(now))
    }

    /// How long a cached response may be reused, given whatever `max-age` the server sent.
    ///
    /// The signature wins whenever it is the shorter of the two: a server that says
    /// `max-age=86400` on a URL that stops verifying in ten minutes is describing its own CDN
    /// policy, not this client's.
    public func cacheLifetime(at now: Date, serverMaxAge: TimeInterval?) -> TimeInterval {
        let signature = remainingLifetime(at: now)
        switch (signature, serverMaxAge) {
        case (nil, nil): return 0
        case (let signature?, nil): return signature
        case (nil, let server?): return max(0, server)
        case (let signature?, let server?): return min(signature, max(0, server))
        }
    }

    /// A request for an already-expired signature must not be answered from cache — the entry can
    /// only be stale, and re-validating it is the whole point.
    public func cachePolicy(at now: Date) -> URLRequest.CachePolicy {
        isExpired(at: now) ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
    }
}

extension MemoAttachment {
    /// The derived-tier URLs this attachment was READ with — the ones a tile has in hand.
    ///
    /// All four are signed in one call (memos-ng `signed_tier_urls`), so they carry one `exp`
    /// between them; all four are still checked, because which tier a surface asks for is the
    /// surface's business and not this rule's.
    public var tierURLs: [URL] {
        [thumbnailURL, previewURL, webURL, posterURL].compactMap { $0 }
    }

    /// Whether the URLs in hand have outlived their signature.
    ///
    /// An UNSIGNED URL never has: `exp` is what expires, and a URL without one is bounded by the
    /// server's own cache headers rather than by a signature this client can read.
    public func isPastURLHorizon(
        at now: Date,
        horizon: TimeInterval = SignedMediaURL.horizon
    ) -> Bool {
        tierURLs.contains { SignedMediaURL(url: $0).isPastHorizon(at: now, horizon: horizon) }
    }
}

/// The image cache the timeline uses — the ON-DISK, across-launches half of the picture.
///
/// Two mechanisms, and it is worth being exact about which does what. The server's
/// `Cache-Control: private, max-age` is what normally bounds an entry's life, and `URLCache`
/// honours it without help. What it does NOT know is that the URL's signature can expire first,
/// so `evictExpired` is the client's own enforcement: before an image is requested, an entry
/// whose signature has already lapsed is dropped, because it can only be stale and re-serving it
/// hides the moment the signature stopped working.
///
/// A cache only counts if the session doing the fetching actually holds it, which is why the
/// image layer builds its own session around one of these (`MediaSession`) instead of installing
/// it into `URLCache.shared` and hoping the shared session had not already been made.
public enum MediaCache {
    /// Sized for a scrolling timeline of thumbnails, not for an offline archive: an on-disk cache
    /// that outgrows the signatures in it is just a pile of URLs that no longer verify.
    ///
    /// It is a `GenerationScopedURLCache`, and that is the whole of the cross-identity fence: every
    /// entry is filed under the fetch generation the request was made in, so bytes fetched for the
    /// account that has signed out are not entries the next account might be served — they are
    /// entries whose key it never forms. See `MediaFetchGeneration`.
    public static func makeURLCache(
        memoryCapacity: Int = 32 * 1024 * 1024,
        diskCapacity: Int = 256 * 1024 * 1024,
        clock: MediaFetchGeneration = .shared
    ) -> URLCache {
        GenerationScopedURLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            diskPath: "memos-media",
            clock: clock
        )
    }

    /// Drops a cached response whose signed URL has expired. Returns whether anything was dropped.
    ///
    /// A response held past `exp` can only be stale, and the signature it was fetched under will
    /// not verify again — so re-serving it hides the moment the URL stopped working, and the fix
    /// is a freshly minted URL from the feed rather than a reload of this one.
    ///
    /// The cache it names by default is the MEDIA session's, not `URLCache.shared`: images are
    /// fetched through `MediaSession`, and evicting out of a cache the fetches never consult is a
    /// no-op that reads like an eviction.
    @discardableResult
    public static func evictExpired(
        _ url: URL,
        at now: Date = Date(),
        cache: URLCache = MediaSession.shared.cache
    ) -> Bool {
        guard SignedMediaURL(url: url).isExpired(at: now) else { return false }
        cache.removeCachedResponse(for: URLRequest(url: url))
        return true
    }

    /// The configuration `MediaSession` is built from. `useProtocolCachePolicy` is named rather
    /// than left implicit: it is the policy that makes the server's `max-age`/`ETag` decide, which
    /// is the whole reason the tiers carry those headers.
    public static func makeSessionConfiguration(cache: URLCache) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return configuration
    }
}
