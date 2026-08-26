import MemosCore
import SwiftUI
import UIKit

/// The bounded store of decoded photos.
///
/// `NSCache` rather than a dictionary for one reason that matters on a phone: it drops its
/// contents when the system says memory is short, without anybody having to subscribe to a
/// notification and get the ordering right. Both limits are set because they bound different
/// things — a count bounds how many rows of scroll-back survive, a cost bounds how many megabytes
/// of bitmap do, and a screen holding one 2048 px photo is a different shape of expensive from one
/// holding twelve 800 px tiles.
final class MediaImageStore {
    private let cache = NSCache<NSString, UIImage>()
    private let identity: MediaIdentity
    private var filledFor: Int

    init(countLimit: Int, totalCostLimit: Int, identity: MediaIdentity = .shared) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        self.identity = identity
        self.filledFor = identity.generation
    }

    /// Emptied the moment the device is a different device, checked on EVERY access rather than
    /// pushed from the sign-out.
    ///
    /// This is RECLAMATION and not the fence — the fence is the key. Every entry is filed under
    /// the generation it was stored in (`MediaImageKey.storageKey(inGeneration:)`), so the
    /// previous identity's photos are not entries this one might be served but entries whose name
    /// it never forms, whether or not this ever ran. What this buys is the megabytes: a store
    /// holding two identities' bitmaps would spend its cost limit on pictures nobody can ask for.
    private func syncToIdentity() {
        let current = identity.generation
        guard current != filledFor else { return }
        cache.removeAllObjects()
        filledFor = current
    }

    /// The generation this store is currently holding images for. A fetch reads it when it starts
    /// and hands it back when it stores, so an answer that outlived its session is refused.
    var generation: Int {
        identity.generation
    }

    var countLimit: Int { cache.countLimit }
    var totalCostLimit: Int { cache.totalCostLimit }

    func image(forKey key: MediaImageKey) -> UIImage? {
        syncToIdentity()
        return cache.object(forKey: storageKey(key) as NSString)
    }

    /// `generation` is what the CALLER read before it went to the network, and it is the
    /// generation the entry is FILED under — not a claim that is checked and then discarded.
    ///
    /// An answer from the previous account, arriving after the switch, is stored under the
    /// previous account's number, where nothing in this identity will ever look for it. That is
    /// what makes the ordering of two racing writers stop mattering: they do not share a key, so
    /// the late one cannot land on top of the live one.
    ///
    /// The returned value is a different question — whether the CALLER may paint this picture.
    /// A stale answer must not be handed to a view even though it was harmlessly filed, because
    /// painting it is the same mistake one frame earlier.
    @discardableResult
    func store(_ image: UIImage, forKey key: MediaImageKey, generation: Int) -> Bool {
        syncToIdentity()
        cache.setObject(
            image,
            forKey: key.storageKey(inGeneration: generation) as NSString,
            cost: Self.cost(of: image)
        )
        return generation == identity.generation
    }

    /// What this identity files under. Read at the moment of the access, never remembered: the
    /// clock can move between two calls, and a key held over from before the move is the previous
    /// account's.
    private func storageKey(_ key: MediaImageKey) -> String {
        key.storageKey(inGeneration: identity.generation)
    }

    /// Drops ONE entry — the decoded half of what `MediaCache.evictExpired` does to the response
    /// cache, and never called on its own: `MediaImageLoader.evictLapsedSignature` is the pair.
    ///
    /// It syncs to the identity clock first for the same reason every other access does. A store
    /// still holding the previous account's images would otherwise remove one key out of them and
    /// leave the rest, which is a cache half-emptied for the wrong reason.
    func remove(forKey key: MediaImageKey) {
        syncToIdentity()
        cache.removeObject(forKey: storageKey(key) as NSString)
    }

    func purge() {
        cache.removeAllObjects()
    }

    /// What one entry costs, in bytes of decoded bitmap.
    ///
    /// The DECODED size, not the length of the JPEG it came from: a 2048 px tier is a few hundred
    /// kilobytes on the wire and about twelve megabytes in memory, and a cost limit fed the wire
    /// size would be out by a factor of thirty. Never zero — `NSCache` treats a zero cost as free
    /// and would let an unbounded number of them in.
    static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }
}

/// Decoding, off the main actor. `nonisolated` is the point of it, not a detail — the package is
/// main-actor by default and this is the expensive part.
nonisolated enum MediaImageDecoder {
    /// `preparingForDisplay` is what makes this a decode rather than a promise of one: `UIImage`
    /// is lazy, and without it the pixels are produced by the render server on the first frame that
    /// draws them — which is exactly the frame this whole file exists to keep cheap.
    static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

/// The photo behind a tile: fetched once, decoded once, and answered synchronously ever after.
///
/// Two things were wrong before this existed, and they are different problems with different
/// fixes. The first is that the same `(uid, tier)` was really reaching the server several times
/// within minutes — an average of 3.66 fetches and as many as 8 — for URLs that were byte-identical
/// and carried correct `Cache-Control`, `ETag` and `Last-Modified`. It is worth being exact about
/// what that does and does not implicate. The app's `URLCache.shared` install is NOT the culprit:
/// the launch probe (`MediaSession.sharedSessionHolds`) reports that the shared session does hold
/// the cache the app installs, so the cache existed and was reachable. Those fetches were simply
/// not being answered out of it — `AsyncImage` never promised to load through `URLSession.shared`,
/// and what it loads through is not something this side can assert, test or fix. Which is the
/// whole argument for owning the session: what this layer fetches through is a session this code
/// built, holding a cache this code attached, and both facts are asserted rather than assumed.
///
/// The second is that even a cache HIT repainted visibly. A `List` builds a fresh view when a row
/// scrolls back, that view starts with no image, and a decode — even from a warm `URLCache` — is
/// asynchronous, so the blurhash flashed underneath every time. A `URLCache` cannot fix that: it
/// stores JPEG bytes, and the frame is lost in the decode. So this keeps the DECODED image, and
/// `cached(for:)` hands it back with no `await` at all, which is what lets a remounted row paint
/// the photo in the same frame it appears in.
///
/// The key is the attachment and the tier, never the URL — the server re-signs every hour and a
/// URL-keyed cache would empty itself on each bucket boundary. See `MediaImageKey`.
public enum MediaImageLoader {
    /// About ten screens of thumbnails in either direction. Scroll-back further than that and a
    /// re-fetch is honest; the cost limit is what actually holds the memory line.
    static let countLimit = 96
    /// 64 MB of decoded bitmap: roughly five full-width 2048 px photos, or thirty 800 px tiles, or
    /// the mixture a real timeline is. Chosen to be worth having and not worth a memory warning —
    /// and when one arrives anyway, `NSCache` sheds the lot without being asked.
    static let totalCostLimit = 64 * 1024 * 1024

    /// A `var` so a test can work in a store of its own: this one is process-wide and bound to the
    /// process-wide identity clock, and a suite asserting what a sign-out empties cannot share it
    /// with a suite asserting what a fetch caches.
    static var store = MediaImageStore(countLimit: countLimit, totalCostLimit: totalCostLimit)

    /// Substituted in tests. Never `URLSession.shared`: that is the session whose cache this app
    /// cannot guarantee, and the reason this layer has one of its own.
    static var transport: any MediaTransport = MediaSession.shared

    public static func key(for attachment: MemoAttachment, tier: MediaTier) -> MediaImageKey {
        MediaImageKey(uid: attachment.uid, tier: tier.rawValue)
    }

    /// Everything held for a key whose signed URL has lapsed, dropped as ONE rule: the response
    /// bytes AND the decoded picture.
    ///
    /// The two layers are cleansed together because they are equally able to paint a stale frame,
    /// and only one of them was being cleansed. `URLCache` is the transport's, and evicting from
    /// it is what stops a lapsed signature being re-served from disk — but this layer keeps the
    /// DECODED image under `(uid, tier)` precisely so that it survives the server re-signing, and
    /// `cached(for:)` is read synchronously in `body`. A tile mounting after the eviction would
    /// therefore paint the old picture instantly, out of memory, with no request to notice — the
    /// entry the eviction was for, one layer up.
    ///
    /// Keyed by `(uid, tier)` and not by the URL, so the entry dropped is the one the lapsed URL
    /// addresses whichever signature it was fetched under.
    ///
    /// Returns whether anything lapsed, so a caller can assert the rule rather than assume it.
    @discardableResult
    static func evictLapsedSignature(
        url: URL,
        key: MediaImageKey,
        at now: Date = Date(),
        cache: URLCache = MediaSession.shared.cache
    ) -> Bool {
        guard MediaCache.evictExpired(url, at: now, cache: cache) else { return false }
        store.remove(forKey: key)
        return true
    }

    /// What has already been decoded, if anything — the common case once a tile has been seen, and
    /// it must not cost a frame to answer. Synchronous by signature, so a view body can read it.
    public static func cached(for key: MediaImageKey) -> Image? {
        cachedUIImage(for: key).map(Image.init(uiImage:))
    }

    static func cachedUIImage(for key: MediaImageKey) -> UIImage? {
        store.image(forKey: key)
    }

    /// The decoded photo for `key`, fetched from `url` only if it is not already held.
    ///
    /// `nil` means the picture could not be produced — no network, a refused signature, or bytes
    /// that are not an image. The caller shows its blurhash and says so rather than retrying in a
    /// loop against a server that has already answered.
    public static func image(for key: MediaImageKey, url: URL) async -> Image? {
        guard let uiImage = await uiImage(for: key, url: url) else { return nil }
        return Image(uiImage: uiImage)
    }

    /// `transport` is defaulted from the installed one and the default is evaluated at the CALL
    /// SITE — before anything here is awaited — so an ordinary caller still fetches through
    /// whatever was in force when it asked. A caller that OWNS the cache it evicts lapsed
    /// signatures out of passes its own instead: that is what lets the full-screen viewer assert
    /// that the session its picture arrives through holds the very `URLCache` it evicts from,
    /// rather than hoping two singletons happen to agree.
    static func uiImage(
        for key: MediaImageKey,
        url: URL,
        transport: any MediaTransport = MediaImageLoader.transport
    ) async -> UIImage? {
        // Before anything is awaited. A hit here is what makes a remount free, and it is also what
        // keeps a second view of the same photo off the wire entirely.
        if let hit = store.image(forKey: key) { return hit }

        // Read BEFORE the network, checked after it. Between these two lines the person can sign
        // out of one server and into another, and this answer would then be about a uid that
        // belongs to somebody else's photo.
        let generation = store.generation

        var request = URLRequest(url: url)
        // A URL whose signature has already lapsed must not be answered out of the URLCache: the
        // entry can only be stale, and the request is going to be refused anyway.
        request.cachePolicy = SignedMediaURL(url: url).cachePolicy(at: Date())
        // The generation travels ON THE REQUEST, and this line is the whole cross-identity fence.
        // The URL loading system caches what it fetched by itself, at the moment the answer lands
        // — which for a fetch that was in flight across a sign-out is after the rotation, so a
        // cache asking the clock at that moment would file the previous account's photo under the
        // new account's number. Stamped here, before the wire, those bytes are filed under the
        // identity that asked for them no matter when they arrive, and the next identity cannot
        // name them. See `GenerationScopedURLCache`.
        MediaFetchGeneration.stamp(&request, generation: generation)

        guard let answer = try? await transport.fetch(request) else { return nil }
        let (data, response) = answer
        guard isUsable(response) else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) {
            MediaImageDecoder.decode(data)
        }.value
        guard let decoded else { return nil }

        // Not stored AND not handed back: the caller would paint it, which is the same mistake
        // one frame earlier.
        guard store.store(decoded, forKey: key, generation: generation) else { return nil }
        return decoded
    }

    /// An error status out of the signed-asset route carries a JSON body, and handing that to
    /// `UIImage(data:)` would produce nil a moment later anyway — but only after it had been paid
    /// for, and a 403 answered from a `URLCache` would be a refusal cached as though it were a
    /// picture. It is cheaper and clearer to refuse it here.
    private static func isUsable(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }
}
