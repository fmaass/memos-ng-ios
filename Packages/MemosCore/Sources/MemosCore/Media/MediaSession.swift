import Foundation

/// What the image layer fetches through. One method, so a test can hand it a scripted answer or
/// no answer at all and still exercise the real loader.
///
/// It is deliberately NOT `URLSession`'s own `data(for:)`: that method carries a defaulted
/// `delegate:` parameter, which cannot satisfy a protocol requirement, and adding an overload
/// that could would make every ordinary call site ambiguous.
public protocol MediaTransport: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// The session the image layer owns, and the only one it ever uses.
///
/// `URLSession` COPIES its configuration when it is created and never reads it again — and
/// `URLSessionConfiguration.default` reads `URLCache.shared` at the moment the configuration is
/// built. Put together, that means `URLSession.shared` binds whatever `URLCache.shared` happened
/// to be the first time anything in the process touched it, and a later
/// `URLCache.shared = <a bigger cache>` cannot reach it. Both halves are asserted in
/// `MediaSessionTests`.
///
/// An app cannot GUARANTEE it wins that race: `URLSession.shared` is materialised by whichever
/// code path touches it first, and in this app two of them are one-line defaults out of sight of
/// the composition root (`APIClientFactory.make(urlSession: .shared)` and
/// `URLSessionHTTPPerformer(session: .shared)` inside `Outbox.live`). As it happens this app does
/// win it — `sharedSessionHolds` reports `true` on launch, which is what establishes that
/// `App.init()` runs before the delegate's `didFinishLaunchingWithOptions` here. That is exactly
/// why the probe is worth logging rather than reasoning about: the answer is a property of a
/// launch, not of the source. Either way the image layer stops depending on it, and holds a
/// session whose cache is attached explicitly.
///
/// `@unchecked Sendable` is justified rather than convenient: both stored properties are `let`,
/// and `URLCache` and `URLSession` are both documented as safe to use from multiple threads.
public final class MediaSession: @unchecked Sendable {
    /// The one cache the image tiers are stored in. It is exposed because eviction
    /// (`MediaCache.evictExpired`) has to name the same cache the fetches go through — evicting
    /// out of `URLCache.shared` while loading through another cache is a no-op that looks correct.
    public let cache: URLCache
    public let session: URLSession

    public init(cache: URLCache = MediaCache.makeURLCache()) {
        self.cache = cache
        self.session = URLSession(configuration: MediaCache.makeSessionConfiguration(cache: cache))
    }

    public static let shared = MediaSession()

    /// Whether the process's SHARED session ended up holding `cache`.
    ///
    /// This is the runtime half of the proof, and it is worth logging once at launch: it answers,
    /// on a real device, whether `URLCache.shared = …` in the composition root actually reached
    /// `URLSession.shared` on that launch — which depends on whether anything had touched the
    /// shared session first, and is therefore not a fact the source can settle. Nothing branches
    /// on it: the image layer no longer cares either way, and that is the point.
    public static func sharedSessionHolds(_ cache: URLCache) -> Bool {
        URLSession.shared.configuration.urlCache === cache
    }
}

extension MediaSession: MediaTransport {
    public func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// What a decoded image is filed under: the attachment and the tier, and nothing else.
///
/// NOT the URL. The server re-mints a signed URL every hour (`bucketed_exp`: the mint time is
/// rounded down to a one-hour bucket, so `exp` and therefore `sig` change on the bucket boundary),
/// and a cache keyed by the URL would throw away every decoded photo each time the feed refreshed
/// across one. The bytes behind `(uid, tier)` do not change when the signature does — that is
/// exactly what makes the pair the right key.
///
/// The tier is a plain string because the enum naming the tiers belongs to the screens, which sit
/// above this layer.
public struct MediaImageKey: Hashable, Sendable {
    public let uid: String
    public let tier: String

    public init(uid: String, tier: String) {
        self.uid = uid
        self.tier = tier
    }

    /// The string form, length-prefixed so it cannot be ambiguous. Without the prefix a uid that
    /// contained the separator could produce the same key as a different (uid, tier) pair, and two
    /// unrelated photos would be served for each other.
    public var storageKey: String {
        "\(uid.utf8.count):\(uid)/\(tier)"
    }
}

/// Which signed-in identity the media layer's decoded images belong to.
///
/// A decoded photo is filed under `(uid, tier)` so that it survives the server re-signing its
/// URLs — which is the whole point of the key, and also the reason it is not safe on its own. A
/// uid is unique to ONE server: two independent memos-ng instances can hand out the same uid for
/// entirely different photos, so a cache that outlives a sign-out would answer server B's tile,
/// synchronously and with no network, using server A's picture.
///
/// Emptying the cache at sign-out is necessary and not sufficient: a fetch already on the wire
/// when the account changed can land afterwards and put A's photo back. So this is a CLOCK, not a
/// signal — a fetch reads it when it starts and again before it stores, and an answer for a
/// generation that has ended is dropped rather than kept. It is the same shape as the session's
/// own generation check on `loadSettings`, for exactly the same reason: dropping a client does
/// not reliably cancel a request already in flight.
///
/// `SessionStore` rotates it at the two moments a device changes who it is — the same two sites
/// that publish and revoke the share extension's account licence.
@MainActor
public final class MediaIdentity {
    public static let shared = MediaIdentity()

    /// Starts at zero and only ever increases, so "has this moved?" is the only question anyone
    /// has to ask of it.
    public private(set) var generation = 0

    public init() {}

    public func rotate() {
        generation += 1
    }
}
