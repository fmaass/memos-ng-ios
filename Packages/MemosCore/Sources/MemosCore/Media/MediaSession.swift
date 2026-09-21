import Foundation
import MemosOutbox

/// What the image layer fetches through. One method, so a test can hand it a scripted answer or
/// no answer at all and still exercise the real loader.
///
/// It is deliberately NOT `URLSession`'s own `data(for:)`: that method carries a defaulted
/// `delegate:` parameter, which cannot satisfy a protocol requirement, and adding an overload
/// that could would make every ordinary call site ambiguous.
public protocol MediaTransport: Sendable {
    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
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
/// code path touches it first, and in this app one such path is a one-line default out of sight of
/// the composition root — `URLSessionHTTPPerformer()` inside `Outbox.live`, whose session argument
/// defaults to `.shared`. The generated client is no longer another: its factory fetches through a
/// session of its own (`APIClientFactory.urlSession`). As it happens this app does
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
    public func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        // On the executor that sends, with nothing between the answer and the request.
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        return try await session.data(for: request)
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

    /// The same key, inside one fetch generation — what the decoded-image store actually files
    /// under.
    ///
    /// A uid is unique to ONE server, so `(uid, tier)` alone is only safe for as long as the
    /// device is the same device. The generation is what makes it safe across a rotation: an
    /// entry the previous identity stored is not an entry the current one prefers not to use, it
    /// is one whose name the current one never forms. Same seam as the response cache
    /// (`GenerationScopedURLCache`), one layer up.
    public func storageKey(inGeneration generation: Int) -> String {
        "g\(generation)/\(storageKey)"
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
/// signal — a fetch reads it when it starts, stamps it on the request, and every cache the answer
/// touches files it under that number. An answer for a generation that has ended is not dropped
/// on trust; it is filed where no later reader looks. It is the same shape as the session's own
/// generation check on `loadSettings`, for exactly the same reason: dropping a client does not
/// reliably cancel a request already in flight.
///
/// The clock itself is `MediaFetchGeneration` — a lock-protected, launch-surviving counter,
/// because the caches it fences are read from the URL loading system's threads and one of them
/// outlives the process. This type is the main-actor face of it that the stores and the session
/// talk to.
///
/// `SessionStore` rotates it at the two moments a device changes who it is — the same two sites
/// that publish and revoke the share extension's account licence.
@MainActor
public final class MediaIdentity {
    public static let shared = MediaIdentity(
        clock: .shared,
        // Resolved when a rotation happens rather than when this is built: `MediaSession.shared`
        // builds a cache, and a static that reaches another static at initialisation is an order
        // dependency nobody can see.
        cache: { MediaSession.shared.cache }
    )

    private let clock: MediaFetchGeneration
    private let cache: () -> (any DerivedMediaCache)?

    /// Starts at zero on a device that has never signed in and only ever increases, so "has this
    /// moved?" is the only question anyone has to ask of it.
    public var generation: Int { clock.current }

    /// A default clock of its own, unpersisted: a test that builds an identity is asking for one
    /// nobody else can move, and a shared counter would make its assertions depend on what
    /// another suite was doing.
    public init(
        clock: MediaFetchGeneration = MediaFetchGeneration(),
        cache: @escaping () -> (any DerivedMediaCache)? = { nil }
    ) {
        self.clock = clock
        self.cache = cache
    }

    /// The device is somebody else now: the clock moves, and the response cache is emptied.
    ///
    /// The emptying is RECLAMATION, not the fence. Nothing depends on it having run — the
    /// previous identity's entries are already unreachable once the clock has moved, because no
    /// reader will form their keys again. What it buys is the 256 MB back, immediately, instead of
    /// leaving it to be evicted as dead weight. That is also why it is safe to do here and was not
    /// safe before: a fetch landing a moment after this line writes under the generation it
    /// STARTED in, so it cannot refill what was just emptied.
    public func rotate() {
        clock.rotate()
        cache()?.removeAllCachedResponses()
    }
}
