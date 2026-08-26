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

/// A transport that stops in the middle, so a test can act while a fetch is on the wire. The two
/// gates are the whole point: `waitUntilStarted` says the request has begun, `release` lets it
/// finish, and between them the test can change who the device is signed in as.
actor GatedTransport: MediaTransport {
    private let payload: Data
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(payload: Data) {
        self.payload = payload
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiting = releaseWaiters
        releaseWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        hasStarted = true
        let waiting = startWaiters
        startWaiters = []
        for waiter in waiting { waiter.resume() }
        if !isReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://memos.example.invalid/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        return (payload, response)
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

/// A gated transport that also CACHES what it answers, the way the URL loading system does: by
/// the time `fetch` returns, the bytes are in the cache. That ORDERING is the whole point — the
/// write lands after the purge, because the purge ran while the request was still on the wire,
/// and no purge can reach bytes that did not exist when it ran.
///
/// `@unchecked Sendable` for the same reason `MediaSession` is: both stored properties are `let`,
/// and `URLCache` is documented as safe to use from several threads.
final class CachingGatedTransport: MediaTransport, @unchecked Sendable {
    let gate: GatedTransport
    private let cache: URLCache

    init(payload: Data, cache: URLCache) {
        gate = GatedTransport(payload: payload)
        self.cache = cache
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await gate.fetch(request)
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
        return (data, response)
    }
}

/// A `URLCache` of a test's own, ON DISK, in a directory it creates and deletes again.
///
/// On disk because that is the half MEMNG-135 is about: the decoded pictures die with the
/// process, and the response bytes do not. Not the media session's cache — that one belongs to
/// the process, and a test that emptied it would be reaching into whatever else is running.
@MainActor
final class ScratchDerivedCache {
    let directory: URL
    let cache: URLCache

    /// What this cache reports on disk while it holds NOTHING — measured, never assumed to be
    /// zero. A `URLCache` with a directory keeps its SQLite database whatever is in it, and an
    /// emptied one reports the size of that file (81920 bytes on the build host, which is not a
    /// number worth writing down). So "the bytes are gone" is this floor, not 0.
    let emptyDiskUsage: Int

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memos-media-\(UUID().uuidString)", isDirectory: true)
        cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 8 << 20, directory: directory)
        // The store is opened on first use, so the floor is read after asking it something —
        // otherwise it is the size of a file that does not exist yet.
        _ = cache.cachedResponse(
            for: URLRequest(url: URL(string: "https://memos.example.invalid/nothing")!)
        )
        emptyDiskUsage = cache.currentDiskUsage
    }

    /// Puts one real response in and proves it landed: "the cache is empty afterwards" says
    /// nothing about emptying it if the cache was never able to hold anything.
    ///
    /// A quarter of a megabyte, so that what reaches the disk is large enough for the byte count
    /// to notice — an 8 px PNG does not move it off the floor. Nothing decodes this, so it does
    /// not have to be a picture.
    @discardableResult
    func seed(_ url: URL) throws -> URLRequest {
        let request = URLRequest(url: url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/jpeg"]
            )
        )
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: Data(repeating: 0x2f, count: 256 << 10)),
            for: request
        )
        #expect(cache.cachedResponse(for: request) != nil, "the seed did not land")
        return request
    }

    /// The entries go; the directory stays. Deleting it while the cache still holds the database
    /// open is what makes libsqlite3 report "vnode unlinked while in use", and it buys nothing:
    /// this is the simulator's own `tmp`, on a device the gate creates and destroys per run.
    func tearDown() {
        cache.removeAllCachedResponses()
    }
}

@MainActor
@Suite("MediaImageLoader", .serialized)
struct MediaImageLoaderTests {
    /// One component in each direction, so it decodes to exactly one colour — `#3E7C4F` — in
    /// every pixel. The same vector `ThumbnailTests` uses, and it is what makes the expected
    /// pixel a number rather than a judgement.
    private static let flatGreenHash = "007Da1"

    /// This test's own identity clock. Swift Testing builds a fresh suite value per test, so the
    /// store installed below is this test's alone.
    let identity = MediaIdentity()

    /// And its own response cache, for the same reason: rotating the clock now empties the
    /// derived cache too, and with the process's own installed here a sign-out test would throw
    /// away the bytes every other suite in the bundle fetches through.
    let derived = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0, directory: nil)

    /// The process-wide store is bound to the process-wide clock, and the sign-out suites rotate
    /// that clock for their own reasons — every rotation emptying the store. Sharing it would make
    /// these assertions depend on what another suite happened to be doing at the time. Everything
    /// that touches the loader lives in THIS suite, and the suite is `.serialized`, so one
    /// installed store is in force for exactly one test at a time.
    init() {
        MediaImageLoader.store = MediaImageStore(
            countLimit: MediaImageLoader.countLimit,
            totalCostLimit: MediaImageLoader.totalCostLimit,
            identity: identity,
            derived: derived
        )
        // Reset rather than restored afterwards: a test that fails part-way through still leaves
        // the next one a real transport, instead of whatever stub it was holding.
        MediaImageLoader.transport = MediaSession.shared
    }

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

    /// Server A's photo, then a switch to server B, then B asking for the SAME uid.
    @Test("after a change of account the previous server's photo is not answered for its uid")
    func aChangeOfAccountEmptiesTheStore() async {
        // A uid both servers use — the case the key alone cannot tell apart.
        let key = MediaImageKey(uid: "shared-uid", tier: "thumb")
        let url = MediaFixture.signed(uid: "shared-uid")
        MediaImageLoader.transport = ScriptedTransport(payload: MediaFixture.png(.red))
        #expect(await MediaImageLoader.uiImage(for: key, url: url) != nil)
        #expect(MediaImageLoader.cached(for: key) != nil, "precondition: A's photo is held")

        identity.rotate()

        #expect(
            MediaImageLoader.cached(for: key) == nil,
            "server A's photo would have been painted for server B's attachment"
        )
    }

    /// The half that emptying the cache cannot fix on its own. The fetch is already on the wire
    /// when the account changes; it lands afterwards, and it must neither be kept nor handed back.
    @Test("an answer that arrives after the account changed is neither cached nor returned")
    func anInFlightAnswerFromTheOldAccountIsDropped() async {
        let key = MediaImageKey(uid: "in-flight", tier: "thumb")
        let url = MediaFixture.signed(uid: "in-flight")
        let gated = GatedTransport(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = gated

        let load = Task { await MediaImageLoader.uiImage(for: key, url: url) }
        await gated.waitUntilStarted()
        identity.rotate()
        await gated.release()
        let answer = await load.value

        #expect(answer == nil, "the previous account's photo was handed back to be painted")
        #expect(MediaImageLoader.cached(for: key) == nil, "and it repopulated the cache")
    }

    /// The control the test above is worthless without: the identical race, with no change of
    /// account in it, still stores and still answers.
    @Test("the same fetch, with no change of account, is kept exactly as before")
    func anInFlightAnswerForTheSameAccountIsKept() async {
        let key = MediaImageKey(uid: "in-flight-control", tier: "thumb")
        let url = MediaFixture.signed(uid: "in-flight-control")
        let gated = GatedTransport(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = gated

        let load = Task { await MediaImageLoader.uiImage(for: key, url: url) }
        await gated.waitUntilStarted()
        await gated.release()
        let answer = await load.value

        #expect(answer != nil)
        #expect(MediaImageLoader.cached(for: key) != nil)
    }

    /// The same arrival one layer down, and the half a purge cannot reach: the request was
    /// already on the wire when the account changed, so the URL loading system caches its bytes
    /// AFTER the purge emptied everything the previous account had. A signed URL stays servable
    /// for about two hours, so what is left behind is a photo of server A's, answerable off the
    /// disk for a uid that now means something else.
    @Test("bytes that arrive after the account changed are not left in the cache")
    func anInFlightAnswerLeavesNoBytesBehind() async throws {
        let scratch = ScratchDerivedCache()
        defer { scratch.tearDown() }
        let key = MediaImageKey(uid: "in-flight-bytes", tier: "thumb")
        let url = MediaFixture.signed(uid: "in-flight-bytes")
        let transport = installCachingTransport(scratch)

        let load = Task { await MediaImageLoader.uiImage(for: key, url: url) }
        await transport.gate.waitUntilStarted()
        identity.rotate()
        // The purge, at the first touch after the clock moved — and before the answer lands,
        // which is exactly why it cannot reach what that answer is about to cache.
        #expect(MediaImageLoader.cached(for: key) == nil)
        await transport.gate.release()
        let answer = await load.value

        #expect(answer == nil, "the previous account's photo was handed back to be painted")
        #expect(MediaImageLoader.cached(for: key) == nil, "and it repopulated the decoded store")
        #expect(
            scratch.cache.cachedResponse(for: URLRequest(url: url)) == nil,
            "the previous account's bytes outlived the purge, ready to answer for its uid"
        )
    }

    /// The control that fence is worthless without: the identical race with NO change of account
    /// keeps its bytes. That cache is the feature — a fence that dropped every answer would send
    /// the timeline back to the server for every tile it has already seen.
    @Test("with no change of account the answer's bytes are kept")
    func anInFlightAnswerForTheSameAccountKeepsItsBytes() async throws {
        let scratch = ScratchDerivedCache()
        defer { scratch.tearDown() }
        let key = MediaImageKey(uid: "in-flight-bytes-control", tier: "thumb")
        let url = MediaFixture.signed(uid: "in-flight-bytes-control")
        let transport = installCachingTransport(scratch)

        let load = Task { await MediaImageLoader.uiImage(for: key, url: url) }
        await transport.gate.waitUntilStarted()
        await transport.gate.release()
        let answer = await load.value

        #expect(answer != nil)
        #expect(MediaImageLoader.cached(for: key) != nil)
        #expect(
            scratch.cache.cachedResponse(for: URLRequest(url: url)) != nil,
            "an answer for the account that asked for it lost its bytes"
        )
    }

    /// Both in-flight tests need the store and the transport pointed at the SAME cache: a fence
    /// asserted against one cache while the fetch writes to another would pass without meaning.
    private func installCachingTransport(_ scratch: ScratchDerivedCache) -> CachingGatedTransport {
        MediaImageLoader.store = MediaImageStore(
            countLimit: MediaImageLoader.countLimit,
            totalCostLimit: MediaImageLoader.totalCostLimit,
            identity: identity,
            derived: scratch.cache
        )
        let transport = CachingGatedTransport(payload: MediaFixture.png(.red), cache: scratch.cache)
        MediaImageLoader.transport = transport
        return transport
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

    // MARK: - one freshness rule across both layers

    /// Evicting a lapsed signature used to cleanse one of the two things that can paint it.
    ///
    /// `URLCache` holds the bytes and is what a fetch is answered from; this layer holds the
    /// DECODED picture under `(uid, tier)` precisely so that it survives the server re-signing,
    /// and `cached(for:)` is read synchronously in a view body. So a tile mounting after the
    /// eviction painted the picture instantly, out of memory, with no request to notice — the
    /// entry the eviction was for, one layer up. Both go, or neither means anything.
    ///
    /// This is also what the viewer's appearance test now proves the WIRING of: that test drives
    /// a real page and asserts the response entry is dropped, and this function is the only path
    /// left to `MediaCache.evictExpired` in this package.
    @Test("a lapsed signature drops the decoded picture as well as the cached response")
    func aLapsedSignatureDropsBothLayers() throws {
        let key = MediaImageKey(uid: "lapsed-both", tier: "thumb")
        let neighbour = MediaImageKey(uid: "lapsed-neighbour", tier: "thumb")
        // Long past whatever clock the simulator runs on.
        let dead = MediaFixture.signed(uid: "lapsed-both", exp: 1)
        let cache = try seeded(dead)
        let request = URLRequest(url: dead)

        let picture = try #require(UIImage(data: MediaFixture.png(.red)))
        let other = try #require(UIImage(data: MediaFixture.png(.blue)))
        let generation = MediaImageLoader.store.generation
        MediaImageLoader.store.store(picture, forKey: key, generation: generation)
        MediaImageLoader.store.store(other, forKey: neighbour, generation: generation)
        // Both really are there beforehand — otherwise the assertions below say nothing.
        #expect(MediaImageLoader.cachedUIImage(for: key) === picture)
        #expect(MediaImageLoader.cachedUIImage(for: neighbour) === other)

        let dropped = MediaImageLoader.evictLapsedSignature(url: dead, key: key, cache: cache)

        #expect(dropped)
        #expect(cache.cachedResponse(for: request) == nil, "the response bytes survived")
        #expect(
            MediaImageLoader.cachedUIImage(for: key) == nil,
            "a lapsed signature left a decoded picture that still paints"
        )
        // The eviction is one key, not a purge: a timeline scrolls past dozens of tiles whose
        // signatures are fine, and emptying the store for one of them would re-fetch all of them.
        #expect(
            MediaImageLoader.cachedUIImage(for: neighbour) === other,
            "an unrelated attachment was dropped with it"
        )
    }

    /// The control: nothing lapsed, nothing dropped. Without it the test above would pass just as
    /// well against an eviction that emptied everything unconditionally.
    @Test("a signature still inside its life drops neither layer")
    func aLiveSignatureDropsNothing() throws {
        let key = MediaImageKey(uid: "live-both", tier: "thumb")
        let live = MediaFixture.signed(uid: "live-both")
        let cache = try seeded(live)
        let request = URLRequest(url: live)

        let picture = try #require(UIImage(data: MediaFixture.png(.green)))
        MediaImageLoader.store.store(
            picture, forKey: key, generation: MediaImageLoader.store.generation
        )

        let dropped = MediaImageLoader.evictLapsedSignature(url: live, key: key, cache: cache)

        #expect(!dropped)
        #expect(cache.cachedResponse(for: request) != nil, "a live signature lost its bytes")
        #expect(MediaImageLoader.cachedUIImage(for: key) === picture)
    }

    /// A cache of this test's OWN, memory-only, holding one response for `url`.
    ///
    /// Not the media session's: that one is a process-wide singleton and disk-backed, so a
    /// seed-then-read against it is a timing test wearing a correctness test's clothes.
    private func seeded(_ url: URL) throws -> URLCache {
        let cache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, directory: nil)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )
        )
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: MediaFixture.png(.red)),
            for: URLRequest(url: url)
        )
        #expect(cache.cachedResponse(for: URLRequest(url: url)) != nil, "the seed did not land")
        return cache
    }
}

@MainActor
@Suite("The decoded-image store")
struct MediaImageStoreTests {
    @Test("the store the loader builds is bounded on both count and cost")
    func limitsAreSet() {
        #expect(MediaImageLoader.countLimit == 96)
        #expect(MediaImageLoader.totalCostLimit == 64 * 1024 * 1024)
        let store = MediaImageStore(
            countLimit: MediaImageLoader.countLimit,
            totalCostLimit: MediaImageLoader.totalCostLimit,
            identity: MediaIdentity()
        )
        #expect(store.countLimit == 96)
        #expect(store.totalCostLimit == 64 * 1024 * 1024)
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
        let store = MediaImageStore(
            countLimit: 4,
            totalCostLimit: 1 << 20,
            identity: MediaIdentity()
        )
        let key = MediaImageKey(uid: "purge", tier: "thumb")
        let image = try #require(UIImage(data: MediaFixture.png(.red)))

        store.store(image, forKey: key, generation: store.generation)
        #expect(store.image(forKey: key) === image)

        store.purge()
        #expect(store.image(forKey: key) == nil)

        store.store(image, forKey: key, generation: store.generation)
        #expect(store.image(forKey: key) === image)
    }

    /// A uid is unique to ONE server, and the bytes behind it stay in the derived cache for as
    /// long as the signature that fetched them is good for — about two hours. Dropping the
    /// decoded pictures and keeping those is emptying one of two caches: the next account asking
    /// for the same uid is answered out of the one that was kept, off the disk, with no request
    /// anybody could notice.
    @Test("a change of account empties the bytes on disk as well as the decoded pictures")
    func aChangeOfAccountEmptiesBothLayers() throws {
        let scratch = ScratchDerivedCache()
        defer { scratch.tearDown() }
        let identity = MediaIdentity()
        let store = MediaImageStore(
            countLimit: 4,
            totalCostLimit: 1 << 20,
            identity: identity,
            derived: scratch.cache
        )
        let key = MediaImageKey(uid: "shared-uid", tier: "thumb")
        let image = try #require(UIImage(data: MediaFixture.png(.red)))
        store.store(image, forKey: key, generation: store.generation)
        let request = try scratch.seed(MediaFixture.signed(uid: "shared-uid"))
        // A second entry, so the assertion below is "the cache holds nothing" rather than "this
        // one key was evicted" — a per-key eviction would satisfy the first pair on its own.
        let neighbour = try scratch.seed(MediaFixture.signed(uid: "another-uid"))
        #expect(store.image(forKey: key) === image, "precondition: the picture is held")

        identity.rotate()

        // The first touch after the clock moved is what syncs — the same one call the loader
        // makes before it goes anywhere near the transport.
        #expect(store.image(forKey: key) == nil, "the previous account's picture is still painted")
        #expect(
            scratch.cache.cachedResponse(for: request) == nil,
            "the previous account's bytes are still there to be served for its uid"
        )
        #expect(
            scratch.cache.cachedResponse(for: neighbour) == nil,
            "one entry went and the rest of the previous account's cache stayed"
        )
        // Back to what an empty one holds. An upper bound rather than an equality: what has not
        // reached the disk yet cannot be counted there, so the pair above is what carries this
        // test and this is the disk saying the same thing.
        #expect(scratch.cache.currentDiskUsage <= scratch.emptyDiskUsage)
    }

    /// The control the test above is worthless without: with the account unchanged, ordinary use
    /// keeps both layers. An unconditional purge would pass that test and re-download the
    /// timeline on every tile.
    @Test("with no change of account the bytes on disk are kept")
    func ordinaryUseKeepsTheBytesOnDisk() throws {
        let scratch = ScratchDerivedCache()
        defer { scratch.tearDown() }
        let store = MediaImageStore(
            countLimit: 4,
            totalCostLimit: 1 << 20,
            identity: MediaIdentity(),
            derived: scratch.cache
        )
        let key = MediaImageKey(uid: "kept", tier: "thumb")
        let image = try #require(UIImage(data: MediaFixture.png(.green)))
        store.store(image, forKey: key, generation: store.generation)
        let request = try scratch.seed(MediaFixture.signed(uid: "kept"))

        // Every access syncs, so "no rotation" has to survive being asked repeatedly.
        #expect(store.image(forKey: key) === image)
        store.remove(forKey: MediaImageKey(uid: "somebody-else", tier: "thumb"))
        #expect(store.image(forKey: key) === image)

        #expect(scratch.cache.cachedResponse(for: request) != nil, "an ordinary read emptied it")
    }

    /// A sign-out on a launch that never loaded a photo takes the same path, and must be a no-op
    /// rather than an error — and must leave a store that still works afterwards.
    @Test("a change of account with nothing cached empties nothing and still answers")
    func aChangeOfAccountWithAnEmptyCacheIsANoOp() throws {
        let scratch = ScratchDerivedCache()
        defer { scratch.tearDown() }
        let identity = MediaIdentity()
        let store = MediaImageStore(
            countLimit: 4,
            totalCostLimit: 1 << 20,
            identity: identity,
            derived: scratch.cache
        )
        let key = MediaImageKey(uid: "nothing-cached", tier: "thumb")
        let request = URLRequest(url: MediaFixture.signed(uid: "nothing-cached"))

        identity.rotate()

        #expect(store.image(forKey: key) == nil)
        #expect(scratch.cache.cachedResponse(for: request) == nil)
        #expect(scratch.cache.currentDiskUsage == scratch.emptyDiskUsage)

        let image = try #require(UIImage(data: MediaFixture.png(.blue)))
        store.store(image, forKey: key, generation: store.generation)
        #expect(store.image(forKey: key) === image, "the rotation left the store unusable")
    }
}

/// What a tile paints when its own capture and the shared cache disagree.
@MainActor
@Suite("What a tile paints")
struct PaintedImageTests {
    private func image(_ color: UIColor) -> UIImage {
        UIImage(data: MediaFixture.png(color))!
    }

    /// The eviction-under-a-mounted-row case. `NSCache` may drop an entry whenever the system is
    /// short of memory, and a row that is still on screen gets no second `.task` — its `id` has
    /// not changed. Without the capture it would fall back to its blurhash and stay there.
    @Test("a captured photo keeps painting after the shared cache has dropped it")
    func aCapturedPhotoSurvivesEviction() {
        let key = MediaImageKey(uid: "mounted", tier: "thumb")
        let captured = image(.red)

        let painted = AttachmentThumbnail.painted(
            captured: (key: key, image: captured),
            for: key,
            cached: nil
        )

        #expect(painted === captured)
    }

    @Test("a capture for another attachment is never painted for this one")
    func aCaptureForAnotherKeyIsIgnored() {
        let mine = MediaImageKey(uid: "mine", tier: "thumb")
        let theirs = MediaImageKey(uid: "theirs", tier: "thumb")
        let fromTheCache = image(.green)

        let painted = AttachmentThumbnail.painted(
            captured: (key: theirs, image: image(.red)),
            for: mine,
            cached: fromTheCache
        )

        #expect(painted === fromTheCache)
    }

    @Test("with nothing captured yet, the shared cache is what paints")
    func withoutACaptureTheCacheIsRead() {
        let key = MediaImageKey(uid: "fresh", tier: "thumb")
        let fromTheCache = image(.green)
        #expect(
            AttachmentThumbnail.painted(captured: nil, for: key, cached: fromTheCache)
                === fromTheCache
        )
        #expect(AttachmentThumbnail.painted(captured: nil, for: key, cached: nil) == nil)
    }

    /// The tier is part of the key, so a preview must not be painted where a thumb was captured.
    @Test("a capture of another tier of the same attachment is not painted either")
    func tiersDoNotSubstituteForEachOther() {
        let thumb = MediaImageKey(uid: "same", tier: "thumb")
        let mobile = MediaImageKey(uid: "same", tier: "mobile")
        #expect(
            AttachmentThumbnail.painted(
                captured: (key: mobile, image: image(.red)),
                for: thumb,
                cached: nil
            ) == nil
        )
    }
}
