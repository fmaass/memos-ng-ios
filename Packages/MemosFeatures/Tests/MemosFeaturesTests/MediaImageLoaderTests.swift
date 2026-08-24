import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// A transport that answers with real image bytes and counts how often it was asked.
///
/// It is the transport that is substituted, never the loader: the store, the key, the decode and
/// the cache-policy decision are all the units under test and all of them run for real.
actor ScriptedTransport: MediaTransport {
    private(set) var calls = 0
    private let payload: Data
    private let status: Int

    init(payload: Data, status: Int = 200) {
        self.payload = payload
        self.status = status
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://memos.example.invalid/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        return (payload, response)
    }
}

/// A transport that never answers at all. Installed to prove that the synchronous path does not
/// go near it: `cached(for:)` is not `async`, so if it ever needed the network this could not
/// compile, and with this in place it could not return either.
actor NeverAnsweringTransport: MediaTransport {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        throw URLError(.cancelled)
    }
}

/// A transport that refuses to answer, and says how often it was asked to. Used where a hang
/// would be the failure — a gate that times out says much less than one that says "0 expected, 1".
actor RefusingTransport: MediaTransport {
    private(set) var calls = 0

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
enum MediaFixture {
    /// Real PNG bytes, encoded here and decoded by the loader — so the decode under test is a
    /// decode, not a value this file made up and then recognised.
    static func png(_ color: UIColor, side: CGFloat = 8) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.pngData()!
    }

    /// A fresh uid per test, so no test can be answered out of another's cache entry.
    static func attachment(uid: String, blurhash: String? = nil) -> MemoAttachment {
        MemoAttachment(
            uid: uid,
            mime: "image/jpeg",
            status: .ready,
            blurhash: blurhash,
            width: 1000,
            height: 1000,
            thumbnailURL: signed(uid: uid)
        )
    }

    /// The shape the server actually mints: `/api/attachments/{uid}/{tier}?exp&scope&sig`.
    static func signed(
        uid: String,
        tier: String = "thumb",
        exp: Int = 4_000_000_000,
        sig: String = "aaaa"
    ) -> URL {
        URL(
            string: "https://memos.example.invalid/api/attachments/\(uid)/\(tier)"
                + "?exp=\(exp)&scope=1&sig=\(sig)"
        )!
    }
}

@MainActor
@Suite("MediaImageLoader", .serialized)
struct MediaImageLoaderTests {
    /// One component in each direction, so it decodes to exactly one colour — `#3E7C4F` — in
    /// every pixel. The same vector `ThumbnailTests` uses, and it is what makes the expected
    /// pixel a number rather than a judgement.
    private static let flatGreenHash = "007Da1"

    private func withTransport(_ transport: any MediaTransport, _ body: () async -> Void) async {
        let previous = MediaImageLoader.transport
        MediaImageLoader.transport = transport
        await body()
        MediaImageLoader.transport = previous
    }

    /// The complaint this whole change answers: the same `(uid, tier)` reaching the server again
    /// and again. Two loads, one fetch, and the SAME decoded object both times.
    @Test("a photo is fetched once and decoded once, however often it is asked for")
    func decodesOnce() async {
        let transport = ScriptedTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let key = MediaImageKey(uid: "decode-once", tier: "thumb")
            let url = MediaFixture.signed(uid: "decode-once")

            let first = await MediaImageLoader.uiImage(for: key, url: url)
            let second = await MediaImageLoader.uiImage(for: key, url: url)

            #expect(first != nil)
            #expect(second === first, "the second ask re-decoded instead of reusing")
            #expect(await transport.calls == 1)
        }
    }

    /// The key is `(uid, tier)`, not the URL. The server re-signs every hour, and a URL-keyed
    /// cache would throw the whole timeline away on each bucket boundary — which is what a photo
    /// re-appearing "for no reason" after an hour of scrolling looks like.
    @Test("a re-signed URL for the same attachment and tier is not a second fetch")
    func theKeySurvivesSignatureRotation() async {
        let transport = ScriptedTransport(payload: MediaFixture.png(.blue))
        await withTransport(transport) {
            let uid = "rotation"
            let key = MediaImageKey(uid: uid, tier: "thumb")
            let earlyBucket = MediaFixture.signed(uid: uid, exp: 4_000_003_600, sig: "1111")
            let laterBucket = MediaFixture.signed(uid: uid, exp: 4_000_007_200, sig: "2222")
            #expect(earlyBucket != laterBucket, "the two URLs must actually differ")

            let first = await MediaImageLoader.uiImage(for: key, url: earlyBucket)
            let second = await MediaImageLoader.uiImage(for: key, url: laterBucket)

            #expect(first != nil)
            #expect(second === first)
            #expect(await transport.calls == 1)
        }
    }

    /// The hot path. `cached(for:)` has no `async` in its signature, so a view body can read it —
    /// and with a transport that never answers anything, it still does.
    @Test("an already-decoded photo is answered with nothing awaited")
    func theCacheIsTheSynchronousPath() async {
        let key = MediaImageKey(uid: "synchronous", tier: "thumb")
        let url = MediaFixture.signed(uid: "synchronous")
        #expect(MediaImageLoader.cached(for: key) == nil, "nothing may have warmed this key")

        await withTransport(ScriptedTransport(payload: MediaFixture.png(.green))) {
            #expect(await MediaImageLoader.uiImage(for: key, url: url) != nil)
        }

        await withTransport(NeverAnsweringTransport()) {
            #expect(MediaImageLoader.cached(for: key) != nil)
        }
    }

    /// The same fact from the other side, asserted where a hang would be the failure: on a hit the
    /// transport is not reached at all.
    @Test("a cached photo does not reach the transport")
    func aHitNeverAsksTheNetwork() async {
        let key = MediaImageKey(uid: "no-network", tier: "thumb")
        let url = MediaFixture.signed(uid: "no-network")
        await withTransport(ScriptedTransport(payload: MediaFixture.png(.orange))) {
            #expect(await MediaImageLoader.uiImage(for: key, url: url) != nil)
        }

        let refusing = RefusingTransport()
        await withTransport(refusing) {
            #expect(await MediaImageLoader.uiImage(for: key, url: url) != nil)
            #expect(await refusing.calls == 0)
        }
    }

    /// A refused signature answers with JSON, not a picture. It must not be kept as one, or the
    /// tile would be permanently "loaded" with nothing in it.
    @Test("an error response is not stored as a photo")
    func refusalsAreNotCached() async {
        let key = MediaImageKey(uid: "refused", tier: "thumb")
        let url = MediaFixture.signed(uid: "refused", sig: "bad")

        let refusal = ScriptedTransport(payload: Data(#"{"detail":"Bad"}"#.utf8), status: 403)
        await withTransport(refusal) {
            #expect(await MediaImageLoader.uiImage(for: key, url: url) == nil)
        }
        #expect(MediaImageLoader.cached(for: key) == nil)

        // And the key is not poisoned: a later good answer is kept.
        await withTransport(ScriptedTransport(payload: MediaFixture.png(.purple))) {
            #expect(await MediaImageLoader.uiImage(for: key, url: url) != nil)
        }
        #expect(MediaImageLoader.cached(for: key) != nil)
    }

    /// The visible half of the complaint, asserted as pixels.
    ///
    /// A `List` builds a fresh tile when a row scrolls back. `ImageRenderer` gives exactly that
    /// situation and nothing else: it renders ONE frame and never runs `.task`, so whatever this
    /// reads was painted with no asynchronous work at all. The attachment's blurhash is flat green
    /// and its photo is flat red, so the pixel says which layer won the first frame.
    @Test("a tile whose photo is already decoded paints the photo in its first frame")
    func aSeenTilePaintsThePhotoImmediately() async throws {
        let uid = "seen-tile"
        let attachment = MediaFixture.attachment(uid: uid, blurhash: Self.flatGreenHash)
        // Both layers warmed, so the assertion can only be measuring which one the tile chose.
        #expect(await BlurHashImage.image(for: Self.flatGreenHash) != nil)
        let key = MediaImageLoader.key(for: attachment, tier: .thumb)
        let url = try #require(MemoPresentation.url(for: attachment, tier: .thumb))
        await withTransport(ScriptedTransport(payload: MediaFixture.png(.red))) {
            #expect(await MediaImageLoader.uiImage(for: key, url: url) != nil)
        }

        let pixel = try #require(
            PixelProbe.centre(
                of: AttachmentThumbnail(attachment: attachment, slot: MemoPresentation.gridSlot),
                size: CGSize(width: 40, height: 40)
            ),
            "the tile rendered nothing at all"
        )
        #expect(pixel.r > 200, "red was \(pixel.r) — the photo did not paint")
        #expect(pixel.g < 80, "green was \(pixel.g) — the blurhash flashed instead")
    }

    /// The control, and the second half of the required behaviour: a tile that has NOT been seen
    /// keeps today's sequence exactly — blurhash first, photo when it lands.
    @Test("a tile that has never been seen still shows its blurhash first")
    func anUnseenTileStillShowsTheBlurhash() async throws {
        let attachment = MediaFixture.attachment(uid: "unseen-tile", blurhash: Self.flatGreenHash)
        #expect(await BlurHashImage.image(for: Self.flatGreenHash) != nil)
        let key = MediaImageLoader.key(for: attachment, tier: .thumb)
        #expect(MediaImageLoader.cached(for: key) == nil, "this uid must not have been loaded")

        let pixel = try #require(
            PixelProbe.centre(
                of: AttachmentThumbnail(attachment: attachment, slot: MemoPresentation.gridSlot),
                size: CGSize(width: 40, height: 40)
            )
        )
        #expect(abs(Int(pixel.r) - 0x3E) <= 8, "red was \(pixel.r)")
        #expect(abs(Int(pixel.g) - 0x7C) <= 8, "green was \(pixel.g)")
        #expect(abs(Int(pixel.b) - 0x4F) <= 8, "blue was \(pixel.b)")
    }

    /// An expired signature must not be answered out of the URLCache — the entry can only be
    /// stale and the request is going to be refused anyway.
    @Test("the request policy follows the signature")
    func expiredSignaturesBypassTheURLCache() {
        let live = MediaFixture.signed(uid: "policy")
        let dead = MediaFixture.signed(uid: "policy", exp: 1)
        #expect(SignedMediaURL(url: live).cachePolicy(at: Date()) == .useProtocolCachePolicy)
        #expect(SignedMediaURL(url: dead).cachePolicy(at: Date()) == .reloadIgnoringLocalCacheData)
    }
}

@MainActor
@Suite("The decoded-image store")
struct MediaImageStoreTests {
    @Test("the shared store is bounded on both count and cost")
    func limitsAreSet() {
        #expect(MediaImageLoader.store.countLimit == 96)
        #expect(MediaImageLoader.store.totalCostLimit == 64 * 1024 * 1024)
    }

    /// The cost is the DECODED size. Fed the length of the JPEG instead, a 64 MB limit would hold
    /// about thirty times more bitmap than it says.
    @Test("an entry costs what its bitmap occupies, and never nothing")
    func costIsTheBitmap() throws {
        let image = try #require(UIImage(data: MediaFixture.png(.red, side: 16)))
        let cgImage = try #require(image.cgImage)
        #expect(MediaImageStore.cost(of: image) == cgImage.bytesPerRow * cgImage.height)
        #expect(MediaImageStore.cost(of: image) >= 16 * 16 * 4)
        // No bitmap at all is still not free: a zero cost is unbounded as far as NSCache cares.
        #expect(MediaImageStore.cost(of: UIImage()) == 1)
    }

    /// What a memory warning does, done by hand. `NSCache` empties itself when the system says
    /// memory is short; this asserts that emptying it does what the tiles depend on.
    @Test("a purged store answers nothing, and can be filled again")
    func purging() throws {
        let store = MediaImageStore(countLimit: 4, totalCostLimit: 1 << 20)
        let key = MediaImageKey(uid: "purge", tier: "thumb")
        let image = try #require(UIImage(data: MediaFixture.png(.red)))

        store.store(image, forKey: key)
        #expect(store.image(forKey: key) === image)

        store.purge()
        #expect(store.image(forKey: key) == nil)

        store.store(image, forKey: key)
        #expect(store.image(forKey: key) === image)
    }
}
