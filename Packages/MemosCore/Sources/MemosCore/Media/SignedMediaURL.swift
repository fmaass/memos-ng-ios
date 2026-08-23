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

    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
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

/// The image cache the timeline uses.
public enum MediaCache {
    /// Sized for a scrolling timeline of thumbnails, not for an offline archive: an on-disk cache
    /// that outgrows the signatures in it is just a pile of URLs that no longer verify.
    public static func makeURLCache(
        memoryCapacity: Int = 32 * 1024 * 1024,
        diskCapacity: Int = 256 * 1024 * 1024
    ) -> URLCache {
        URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            diskPath: "memos-media"
        )
    }

    public static func makeSessionConfiguration(cache: URLCache) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return configuration
    }
}
