import Foundation

/// Which signed-in identity a set of fetched bytes belongs to, as a number that any thread may
/// read and that every media request carries with it.
///
/// This is the SEAM the cross-identity media leak is closed at, and it exists because the
/// alternative was proven not to work. Emptying the caches at a rotation is a purge that runs at
/// one instant, and a fetch that was already on the wire lands after it: its bytes are the
/// previous account's, and they are written by the URL loading system on its own account, under
/// no clock of ours. Three rounds of review on the first attempt each found another way for a
/// late writer to reach a live reader — a fetch that threw after its body had been cached, a
/// removal by URL that evicted the LIVE account's entry, two writers landing in the reverse
/// order. They are not three defects. They are one: stale and live bytes sharing a cache key.
///
/// So the generation is part of the key rather than the subject of a purge. A fetch reads the
/// generation when it starts, stamps it on its request, and every cache the request touches files
/// what it holds under that number (`GenerationScopedURLCache`, `MediaImageKey.storageKey(in:)`).
/// A reader only ever forms keys for the generation it is in. The counter only increases, so a
/// key from a previous identity is not merely emptied — it is a key nobody will ever ask for
/// again. The race class is unreachable by construction, and there is no enumerated list of purge
/// sites to keep complete.
///
/// It is PERSISTED because the fence has to survive a launch. The counter is per-process, so a
/// relaunch would restart it at zero and the next account's fetches would form exactly the keys
/// the previous account's bytes are filed under — a 256 MB on-disk cache that outlives the
/// process makes that a real path, not a theoretical one.
///
/// `@unchecked Sendable` is the honest declaration rather than a convenient one: the counter is
/// read from whichever thread the URL loading system is caching on, and the lock is what makes
/// that safe.
public final class MediaFetchGeneration: @unchecked Sendable {
    /// Where the counter survives a launch.
    public static let defaultsKey = "media.fetchGeneration"

    /// The header a request carries its generation in.
    ///
    /// On the REQUEST rather than read from the clock at cache time, and that distinction is the
    /// whole fence: a stale answer is cached at the moment it lands, which is after the rotation,
    /// so a cache that asked the clock then would file the previous account's photo under the new
    /// account's number. The request knows which identity asked for it; the clock only knows what
    /// time it is now.
    public static let headerField = "X-Memos-Fetch-Generation"

    /// The one the app fetches under. Backed by `UserDefaults.standard` — the same store the app's
    /// other launch-surviving settings use, and not the app group: nothing outside this process
    /// fetches media.
    public static let shared = MediaFetchGeneration(defaults: .standard)

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let key: String
    private var value: Int

    /// `defaults: nil` is a counter that does not survive anything — which is what a test wants,
    /// and what makes one test's rotations invisible to another's.
    public init(defaults: UserDefaults? = nil, key: String = MediaFetchGeneration.defaultsKey) {
        self.defaults = defaults
        self.key = key
        // `integer(forKey:)` answers 0 for a key that was never written, which is exactly the
        // first generation. A first launch and a launch after a wipe are the same case.
        self.value = defaults?.integer(forKey: key) ?? 0
    }

    public var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// The device is somebody else now. Monotonic and never reset: "later than" is the only
    /// question anyone asks of it, and a counter that could go backwards would hand a new identity
    /// a key an old one's bytes are already filed under.
    @discardableResult
    public func rotate() -> Int {
        lock.lock()
        value += 1
        let rotated = value
        lock.unlock()
        // Written outside the lock: `UserDefaults` takes its own, and holding two locks in an
        // order nobody else knows about is how a deadlock is built.
        defaults?.set(rotated, forKey: key)
        return rotated
    }

    /// Stamps the generation this fetch belongs to onto the request that carries it.
    public static func stamp(_ request: inout URLRequest, generation: Int) {
        request.setValue(String(generation), forHTTPHeaderField: headerField)
    }

    public func stamp(_ request: inout URLRequest) {
        Self.stamp(&request, generation: current)
    }

    public static func stamped(_ request: URLRequest, generation: Int) -> URLRequest {
        var stamped = request
        stamp(&stamped, generation: generation)
        return stamped
    }

    /// The generation a request was made under, or `nil` for a request that was not made by the
    /// media layer at all. Never a default: a caller that cannot tell must fail closed rather than
    /// guess, and guessing is precisely what the write-time clock did.
    public static func generation(of request: URLRequest) -> Int? {
        guard let raw = request.value(forHTTPHeaderField: headerField) else { return nil }
        return Int(raw)
    }
}
