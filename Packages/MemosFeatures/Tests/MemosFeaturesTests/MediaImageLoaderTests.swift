import Foundation
import MemosCore
import MemosOutbox
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
    /// Every request as it went out. What the generation fence is asserted against: the stamp a
    /// request carries is what the caches file its answer under, so "which identity do these
    /// bytes belong to" is a question about this array.
    private(set) var requests: [URLRequest] = []
    private let payload: Data
    private let status: Int

    init(payload: Data, status: Int = 200) {
        self.payload = payload
        self.status = status
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        calls += 1
        requests.append(request)
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
    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        throw URLError(.cancelled)
    }
}

/// A transport that refuses to answer, and says how often it was asked to. Used where a hang
/// would be the failure — a gate that times out says much less than one that says "0 expected, 1".
actor RefusingTransport: MediaTransport {
    private(set) var calls = 0

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        calls += 1
        throw URLError(.notConnectedToInternet)
    }
}

/// A transport that refuses the first request and answers every one after it: the connection that
/// dropped and came back. Counting calls says a second request was made; answering the second one
/// with real bytes is what lets a case assert the picture the retry was for actually arrives.
actor RecoveringTransport: MediaTransport {
    private(set) var calls = 0
    private let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        calls += 1
        guard calls > 1 else { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://memos.example.invalid/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        return (payload, response)
    }
}

/// A transport that holds EVERY request until the case lets that one through, by the order it
/// arrived. `GatedTransport` below releases them all at once, which cannot express two requests
/// from the same view ending in the wrong order — the case that matters when one of them was
/// cancelled and the other is still out.
actor HeldTransport: MediaTransport {
    private let payload: Data
    private(set) var calls = 0
    private var holding: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var refused: Set<Int> = []
    private var freeForAll = false
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var urls: [Int: URL] = [:]

    init(payload: Data) {
        self.payload = payload
    }

    /// How many requests so far carried this text in their URL. Two loads of the SAME tile differ
    /// only by the signature on the link, so an ordinal cannot name one of them and the link can.
    func calls(matching text: String) -> Int {
        urls.values.filter { $0.absoluteString.contains(text) }.count
    }

    /// Lets through every request already here whose URL carries this text.
    func release(matching text: String, refusing: Bool = false) {
        for (ordinal, url) in urls where url.absoluteString.contains(text) {
            release(ordinal, refusing: refusing)
        }
    }

    /// Returns once at least `count` requests have reached the transport.
    func waitUntilStarted(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    /// Lets the `ordinal`-th request through, refusing it or answering it; the rest stay held.
    func release(_ ordinal: Int, refusing: Bool = false) {
        if refusing { refused.insert(ordinal) }
        released.insert(ordinal)
        holding.removeValue(forKey: ordinal)?.resume()
    }

    /// Lets everything through, so a case never ends leaving a request suspended for good.
    func releaseAll() {
        freeForAll = true
        let waiting = holding
        holding = [:]
        for (_, continuation) in waiting { continuation.resume() }
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        calls += 1
        let ordinal = calls
        urls[ordinal] = request.url
        let ready = startWaiters.filter { $0.count <= calls }
        startWaiters.removeAll { $0.count <= calls }
        for waiter in ready { waiter.continuation.resume() }

        if !freeForAll, !released.contains(ordinal) {
            await withCheckedContinuation { holding[ordinal] = $0 }
        }
        if refused.contains(ordinal) { throw URLError(.notConnectedToInternet) }

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://memos.example.invalid/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        return (payload, response)
    }
}

/// A transport that is cancelled rather than answered. Both shapes of it: the structured error a
/// cancelled task throws, and the one `URLSession` reports when the task it belongs to is torn
/// down — which is what a scrolled row and a slow link actually produce.
actor AbandoningTransport: MediaTransport {
    enum Shape {
        case structured
        case session
    }

    private let shape: Shape
    private(set) var calls = 0

    init(shape: Shape = .structured) {
        self.shape = shape
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        calls += 1
        switch shape {
        case .structured: throw CancellationError()
        case .session: throw URLError(.cancelled)
        }
    }
}

/// A transport that refuses the FIRST ask for one named attachment — the lapsed signature, in the
/// shape the server sends it — and answers everything else with a picture, remembering every URL
/// it was asked for.
///
/// One transport for two tiles on screen is what lets a single case hold both halves of the rule:
/// the tile that failed is asked again, and the tile that did not is left alone. Asserted by uid,
/// because "how many times in all" cannot tell those two apart.
actor LapsedSignatureTransport: MediaTransport {
    private let payload: Data
    private let lapsed: String
    private(set) var asked: [URL] = []
    private var refusals = 0

    init(payload: Data, lapsedFor uid: String) {
        self.payload = payload
        self.lapsed = uid
    }

    /// How often this attachment was asked for, whatever the signature on the link.
    func asks(for uid: String) -> Int {
        asked.filter { $0.path.contains(uid) }.count
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        let url = request.url ?? URL(string: "https://memos.example.invalid/")!
        asked.append(url)
        let isLapsed = url.path.contains(lapsed) && refusals == 0
        if isLapsed { refusals += 1 }
        let response = HTTPURLResponse(
            url: url,
            statusCode: isLapsed ? 403 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": isLapsed ? "application/json" : "image/png"]
        )!
        return (isLapsed ? Data(#"{"detail":"Signature expired"}"#.utf8) : payload, response)
    }
}

/// A transport that stops in the middle, so a test can act while a fetch is on the wire. The two
/// gates are the whole point: `waitUntilStarted` says the request has begun, `release` lets it
/// finish, and between them the test can change who the device is signed in as.
actor GatedTransport: MediaTransport {
    private let payload: Data
    /// Every request as it went out — see `ScriptedTransport.requests`.
    private(set) var requests: [URLRequest] = []
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

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        requests.append(request)
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

/// One attachment a case can change while the tile built from it stays mounted — the freshly
/// signed link a list hands the same row on the next read.
@MainActor
@Observable
final class TileSubject {
    var attachment: MemoAttachment

    init(_ attachment: MemoAttachment) {
        self.attachment = attachment
    }
}

/// The tile as a list holds it: rebuilt from the subject whenever the subject changes, in the same
/// position, so the tile keeps the state its load lives in.
struct TileHost: View {
    let subject: TileSubject

    var body: some View {
        AttachmentThumbnail(attachment: subject.attachment, slot: MemoPresentation.gridSlot)
    }
}

/// Two tiles side by side in ONE window: the one under examination on the left, and on the right a
/// tile that is MEANT to fail.
///
/// One window so that both tiles are committed, drawn and read through the same path. A glyph on
/// the right is therefore not merely evidence that the pixel reading works — it is evidence that a
/// failure the left tile was holding would have been drawn and read too, which is what makes "no
/// triangle" an observation rather than a wait.
struct TilePairHost: View {
    let subject: TileSubject
    let control: MemoAttachment

    var body: some View {
        HStack(spacing: 0) {
            TileHost(subject: subject)
            AttachmentThumbnail(attachment: control, slot: MemoPresentation.gridSlot)
        }
    }
}

@MainActor
@Suite("MediaImageLoader", .serialized, .mediaGlobals)
struct MediaImageLoaderTests {
    /// One component in each direction, so it decodes to exactly one colour — `#3E7C4F` — in
    /// every pixel. The same vector `ThumbnailTests` uses, and it is what makes the expected
    /// pixel a number rather than a judgement.
    private static let flatGreenHash = "007Da1"

    /// This test's own identity clock. Swift Testing builds a fresh suite value per test, so the
    /// store installed below is this test's alone.
    let identity = MediaIdentity()

    /// The process-wide store is bound to the process-wide clock, and the sign-out suites rotate
    /// that clock for their own reasons — every rotation emptying the store. Sharing it would make
    /// these assertions depend on what another suite happened to be doing at the time. Everything
    /// that touches the loader lives in THIS suite, and the suite is `.serialized`, so one
    /// installed store is in force for exactly one test at a time.
    init() {
        MediaImageLoader.store = MediaImageStore(
            countLimit: MediaImageLoader.countLimit,
            totalCostLimit: MediaImageLoader.totalCostLimit,
            identity: identity
        )
        // Reset rather than restored afterwards: a test that fails part-way through still leaves
        // the next one a real transport, instead of whatever stub it was holding.
        MediaImageLoader.transport = MediaSession.shared
        // A fresh table too: a request a previous case left held would otherwise be joined.
        MediaImageLoader.flights = MediaFetchTable()
        // This test's own signal, for the reason the store is this test's own: it is read by every
        // mounted tile in the process, and a case that publishes on it must not be telling some
        // other suite's view to fetch.
        MediaRetrySignal.shared = MediaRetrySignal()
    }

    /// Waits for what a view on screen does on its own turn, and gives up rather than hanging: a
    /// case that says "1 expected, 2" is worth more than one that times the bundle out.
    func eventually(tries: Int = 80, _ condition: () async -> Bool) async -> Bool {
        for _ in 0..<tries {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    /// A tile in a window of its own, so its `.task` runs and what it does is what a person would
    /// be looking at. `ImageRenderer` cannot be used here: it draws one frame and never runs a
    /// task, which is the whole of what these cases are about.
    func hostedTile(for attachment: MemoAttachment) -> UIWindow {
        host(TileHost(subject: TileSubject(attachment)))
    }

    /// The tile under examination beside one that is meant to fail, in one window — see
    /// `TilePairHost` for why they share it. Left tile and right tile are `Self.leftTile` and
    /// `Self.rightTile`.
    func hostedPair(subject: TileSubject, control: MemoAttachment) -> UIWindow {
        host(
            TilePairHost(subject: subject, control: control),
            size: CGSize(width: Self.tileSide * 2, height: Self.tileSide)
        )
    }

    private static let tileSide: CGFloat = 120
    static let leftTile = CGRect(x: 0, y: 0, width: tileSide, height: tileSide)
    static let rightTile = CGRect(x: tileSide, y: 0, width: tileSide, height: tileSide)

    /// The same attachment the server would hand back on the next read: same uid, same tier, a
    /// freshly minted signature. The blurhash is the flat one, so every pixel a tile paints
    /// underneath its picture is a known colour and none of them is white.
    func tile(uid: String, sig: String) -> MemoAttachment {
        MemoAttachment(
            uid: uid,
            mime: "image/jpeg",
            status: .ready,
            blurhash: Self.flatGreenHash,
            width: 1000,
            height: 1000,
            thumbnailURL: MediaFixture.signed(uid: uid, sig: sig)
        )
    }

    private func host(
        _ view: some View,
        size: CGSize = CGSize(width: 120, height: 120)
    ) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = UIHostingController(rootView: view)
        // Black behind everything: a tile is clipped to rounded corners, so whatever is behind it
        // shows at all four of them, and a white default would be counted as a glyph.
        window.backgroundColor = .black
        window.rootViewController?.view.backgroundColor = .black
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    /// What a mounted tile is PAINTING, counted in white pixels, over the whole window or over one
    /// region of it in the window's own coordinates.
    ///
    /// The failure glyph is white and nothing else on these tiles is — their blurhash is flat
    /// green and their picture flat red — so this number is a statement about the triangle. A
    /// tile's load and its state are its own, and the only honest reading of either is off the
    /// window the tile is really in.
    ///
    /// The capture follows `SettingsRenderTests.render`, down to letting the run loop turn before
    /// it draws: a hierarchy snapshot taken without that comes back with nothing in it, because
    /// what a state change queued has not been committed yet. The scale is pinned for the reason
    /// it is pinned there — the gate uses whichever simulator the build host has newest.
    func glyphPixels(in window: UIWindow, within region: CGRect? = nil) -> Int {
        guard let view = window.rootViewController?.view else { return 0 }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        let shot = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = shot.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return 0
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return }
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            )
        }
        // The view is measured in points and the shot in pixels; the region is given in points, so
        // it is scaled by what was actually drawn rather than by the number asked for above.
        let scale = CGFloat(width) / max(view.bounds.width, 1)
        let box = (region ?? view.bounds).applying(CGAffineTransform(scaleX: scale, y: scale))
        let firstColumn = max(Int(box.minX.rounded()), 0)
        let lastColumn = min(Int(box.maxX.rounded()), width)
        let firstRow = max(Int(box.minY.rounded()), 0)
        let lastRow = min(Int(box.maxY.rounded()), height)
        guard firstColumn < lastColumn, firstRow < lastRow else { return 0 }
        var white = 0
        for y in firstRow..<lastRow {
            for x in firstColumn..<lastColumn {
                let pixel = (y * width + x) * 4
                if bytes[pixel] > 200 && bytes[pixel + 1] > 200 && bytes[pixel + 2] > 200 {
                    white += 1
                }
            }
        }
        return white
    }

    /// Not private because the Places pin view is a loader caller too, and its two cases belong in
    /// THIS suite for the reason the suite exists (above) — they are declared in an extension of
    /// it, from another file.
    func withTransport(_ transport: any MediaTransport, _ body: () async -> Void) async {
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

    /// An expired signature must not be answered out of the URLCache — the entry can only be
    /// stale and the request is going to be refused anyway.
    @Test("the request policy follows the signature")
    func expiredSignaturesBypassTheURLCache() {
        let live = MediaFixture.signed(uid: "policy")
        let dead = MediaFixture.signed(uid: "policy", exp: 1)
        #expect(SignedMediaURL(url: live).cachePolicy(at: Date()) == .useProtocolCachePolicy)
        #expect(SignedMediaURL(url: dead).cachePolicy(at: Date()) == .reloadIgnoringLocalCacheData)
    }

    // MARK: - a picture nobody answered about

    /// The distinction the whole enumeration exists for, taken from the loader's own call rather
    /// than argued about: a fetch that was abandoned is not a word about the file, and a fetch the
    /// server refused is.
    @Test("a cancelled fetch is not an answer, and a refused one is")
    func anAbandonedFetchIsNotAnAnswer() async {
        let key = MediaImageKey(uid: "abandoned", tier: "thumb")
        let url = MediaFixture.signed(uid: "abandoned")

        // Both shapes a cancellation reaches this layer in.
        for shape in [AbandoningTransport.Shape.structured, .session] {
            let transport = AbandoningTransport(shape: shape)
            await withTransport(transport) {
                #expect(await MediaImageLoader.answer(for: key, url: url) == .interrupted)
                #expect(await transport.calls == 1, "the fetch never reached the transport")
            }
        }

        // The control: a refusal answered by the server is an answer, and the optional mapping
        // every other caller still uses cannot tell the two apart — which is why it is the views
        // that were given the difference.
        let refusal = ScriptedTransport(payload: Data(#"{"detail":"Bad"}"#.utf8), status: 403)
        await withTransport(refusal) {
            #expect(await MediaImageLoader.answer(for: key, url: url) == .unavailable)
            #expect(await MediaImageLoader.uiImage(for: key, url: url) == nil)
        }

        // And a picture is still a picture, so the two lines above are about the answers and not
        // about a function that stopped producing one.
        await withTransport(ScriptedTransport(payload: MediaFixture.png(.red))) {
            #expect(await MediaImageLoader.answer(for: key, url: url) != .unavailable)
            #expect(await MediaImageLoader.uiImage(for: key, url: url) != nil)
        }

        // Which errors mean "never answered", asserted rather than inferred from a fetch that
        // happened to be cancelled at the right moment.
        #expect(MediaImageLoader.wasAbandoned(CancellationError()))
        #expect(MediaImageLoader.wasAbandoned(URLError(.cancelled)))
        #expect(!MediaImageLoader.wasAbandoned(URLError(.notConnectedToInternet)))
    }

    /// The morning the owner reopened the app to a card of warning triangles: the links held from
    /// the evening before had lapsed, every picture was refused, and nothing on the phone asked
    /// again — the list came back with byte-identical URLs, so no tile saw anything change.
    ///
    /// Both halves of the rule in one case, because "one attempt per failed tile, none for the
    /// loaded ones" is a statement about two tiles: the same signal, the same moment, and the
    /// counts read per attachment.
    @Test("the list coming back asks again for the tile that failed, and for no other")
    func onlyTheFailedTileIsAskedAgain() async {
        let lapsed = "tile-lapsed"
        let held = "tile-held"
        let transport = LapsedSignatureTransport(payload: MediaFixture.png(.red), lapsedFor: lapsed)
        await withTransport(transport) {
            let failing = MediaFixture.attachment(uid: lapsed)
            let loaded = MediaFixture.attachment(uid: held)
            let failedKey = MediaImageLoader.key(for: failing, tier: .thumb)
            let loadedKey = MediaImageLoader.key(for: loaded, tier: .thumb)
            let windows = [hostedTile(for: failing), hostedTile(for: loaded)]

            let settled = await eventually {
                await transport.asks(for: lapsed) == 1
                    && MediaImageLoader.cachedUIImage(for: loadedKey) != nil
            }
            #expect(settled, "the two tiles never finished their first load")
            #expect(
                MediaImageLoader.cachedUIImage(for: failedKey) == nil,
                "the refused tile was supposed to end its first load with nothing"
            )

            // The list was read again. Nothing else changed: the same window, the same tiles,
            // the same links.
            //
            // Published until the ask is seen, and that is not a workaround for a race: a
            // publication that lands before the refused tile has let go of its claim is REFUSED,
            // which is the rule this whole change is built on, and the next one carries it. A
            // case that published once and then waited would be asserting which main-actor job
            // ran first.
            let askedAgain = await eventually {
                MediaRetrySignal.shared.publish()
                return await transport.asks(for: lapsed) == 2
            }
            #expect(askedAgain, "the tile kept its warning triangle after the list came back")

            let painted = await eventually { MediaImageLoader.cachedUIImage(for: failedKey) != nil }

            // A tile that HAS its picture stays off the wire, however often the list comes back.
            // Each try publishes and then reads: an ask accepted in one try is in the array before
            // the next one looks, because the transport records a request as it enters rather than
            // when it answers.
            let askedThrice = await eventually(tries: 8) {
                MediaRetrySignal.shared.publish()
                return await transport.asks(for: lapsed) > 2
            }
            #expect(!askedThrice, "the tile went back to the network for a picture it holds")

            let askedForFailed = await transport.asked.filter { $0.path.contains(lapsed) }
            // Read AFTER the failed tile's second fetch has been answered — strictly later than
            // the publication both tiles saw, so a loaded tile that had asked again would have
            // its request in this array already. No window is being trusted.
            let askedForLoaded = await transport.asks(for: held)
            for window in windows { window.isHidden = true }

            #expect(painted, "the picture the second ask brought back never reached the tile")
            #expect(askedForFailed.count == 2, "\(askedForFailed.count) asks for the failed tile")
            #expect(
                askedForFailed.first == askedForFailed.last,
                "the retry only happened because the link had changed, which proves nothing"
            )
            #expect(askedForLoaded == 1, "a tile holding its picture was sent back to the network")
        }
    }

    /// The refusal the rule is built on, on the wire rather than in a value: a tile whose request
    /// is still out is showing nothing, which is exactly what a tile owed a picture looks like.
    /// Asking again there would put the same bytes on the wire twice and blank the tile meanwhile.
    @Test("a signal arriving while the tile's fetch is out puts nothing on the wire")
    func aSignalIsRefusedWhileTheTilesFetchIsOut() async {
        let transport = HeldTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let attachment = MediaFixture.attachment(uid: "tile-in-flight")
            let key = MediaImageLoader.key(for: attachment, tier: .thumb)
            let window = hostedTile(for: attachment)
            await transport.waitUntilStarted(1)

            // Published over and over while the first request is still held. `HeldTransport`
            // counts a request the instant it ENTERS and only then suspends, so a second one
            // started at any point in this loop is recorded the moment it starts: what is being
            // searched for is a REQUEST, not the passing of a duration.
            let askedAgain = await eventually(tries: 8) {
                MediaRetrySignal.shared.publish()
                return await transport.calls > 1
            }
            #expect(!askedAgain, "a tile with a request already out asked again")
            #expect(await transport.calls == 1)

            // And the tile is not stranded by the refusal: the fetch it was holding still paints.
            await transport.releaseAll()
            let painted = await eventually { MediaImageLoader.cachedUIImage(for: key) != nil }
            window.isHidden = true
            #expect(painted, "the fetch that was let through never reached the tile")
        }
    }

    /// A row is handed the same picture on a fresh signature while its first fetch is still out:
    /// that fetch is abandoned, a second goes out for the identical `(uid, tier)`, and only then
    /// does the first one come back refused.
    ///
    /// Nobody is waiting for that refusal, and a tile that paints it is putting a warning triangle
    /// on a picture it is fetching at that very moment.
    @Test("a refusal for a load that was superseded leaves the tile alone")
    func aSupersededRefusalDoesNotFailTheTile() async {
        let uid = "tile-superseded"
        let transport = HeldTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let subject = TileSubject(tile(uid: uid, sig: "aaaa"))
            let key = MediaImageLoader.key(for: subject.attachment, tier: .thumb)
            let control = tile(uid: "tile-beside", sig: "cccc")
            let window = hostedPair(subject: subject, control: control)

            let started = await eventually {
                let examined = await transport.calls(matching: "sig=aaaa")
                let alongside = await transport.calls(matching: "sig=cccc")
                return examined == 1 && alongside == 1
            }
            #expect(started, "the two tiles never reached the transport")

            // The list came back. Same picture, same tier, a link signed afresh — so the load now
            // out is for the very key the first one was asked about.
            subject.attachment = tile(uid: uid, sig: "bbbb")
            let superseded = await eventually {
                await transport.calls(matching: "sig=bbbb") == 1
            }
            #expect(superseded, "the re-signed link never reached the transport")

            // The abandoned request is refused; the tile beside it is refused after that, through
            // the same transport and the same path back to the screen.
            await transport.release(matching: "sig=aaaa", refusing: true)
            await transport.release(matching: "sig=cccc", refusing: true)

            // Fewer tries than elsewhere because each one draws the window and lets the run loop
            // turn: this waits seconds, not milliseconds.
            let drewIt = await eventually(tries: 10) {
                glyphPixels(in: window, within: Self.rightTile) > 0
            }
            // A second draw of the same window, taken after the one that showed a triangle. The
            // abandoned request was refused FIRST, so a tile that took that refusal has held its
            // failure for longer than the tile beside it, and a failure stays until something asks
            // again — nothing here does. It would be in this draw.
            let examined = glyphPixels(in: window, within: Self.leftTile)
            #expect(drewIt, "the tile that really failed drew nothing — nothing is being read here")
            #expect(examined == 0, "a superseded refusal put the warning triangle back")

            // And refusing the stale answer costs the tile nothing: the load that IS waited on
            // still paints.
            await transport.release(matching: "sig=bbbb")
            let painted = await eventually { MediaImageLoader.cachedUIImage(for: key) != nil }
            await transport.releaseAll()
            window.isHidden = true
            #expect(painted, "the picture the live load brought back never reached the tile")
        }
    }

    /// Two signals with nothing between them — the app coming back to the foreground in the same
    /// turn its list finishes reading — are ONE opportunity to ask, not two.
    @Test("two signals in one stretch put a single new request on the wire")
    func twoSignalsInOneStretchAskOnce() async {
        let transport = HeldTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let attachment = tile(uid: "tile-two-signals", sig: "aaaa")
            let key = MediaImageLoader.key(for: attachment, tier: .thumb)
            let window = hostedTile(for: attachment)
            await transport.waitUntilStarted(1)
            await transport.release(1, refusing: true)

            // Wait for the triangle itself, off the window: it is the only thing that says the
            // refusal has been taken AND the claim let go, which is the state the signal is about.
            let failed = await eventually(tries: 10) { glyphPixels(in: window) > 0 }
            #expect(failed, "the refused tile never drew its warning triangle")

            // Both publications in one synchronous stretch, and the stretch repeated. SwiftUI may
            // deliver two changes made with no suspension between them as a single notification,
            // so the pair by itself cannot show a refusal; the repeats are separate turns, and
            // each is a fresh chance for a second request to escape if nothing refuses it.
            let askedAgain = await eventually {
                MediaRetrySignal.shared.publish()
                MediaRetrySignal.shared.publish()
                return await transport.calls == 2
            }
            #expect(askedAgain, "the tile kept its warning triangle after the list came back")

            // The new request is HELD, and the transport counts a request as it enters rather than
            // when it answers, so one starting at any point in this loop is recorded the moment it
            // starts: the count staying at 2 is an observation, not a duration that passed.
            let askedThrice = await eventually(tries: 8) {
                MediaRetrySignal.shared.publish()
                MediaRetrySignal.shared.publish()
                return await transport.calls > 2
            }
            #expect(!askedThrice, "a tile with a request already out asked again")
            #expect(await transport.calls == 2)

            await transport.releaseAll()
            let painted = await eventually { MediaImageLoader.cachedUIImage(for: key) != nil }
            window.isHidden = true
            #expect(painted, "the picture the second ask brought back never reached the tile")
        }
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

    // MARK: - The cross-identity fence

    /// The property everything else rests on: a fetch is filed under the identity that ASKED for
    /// it, not the one that happens to be signed in when it lands.
    ///
    /// The response bytes are cached by the URL loading system itself, on its own account, at the
    /// moment the answer arrives — which for a fetch that was in flight across a sign-out is after
    /// the rotation. A cache that read the clock then would file the previous account's photo
    /// under the new account's number, and every purge in the world runs too early to catch it.
    /// The stamp on the request is what makes that impossible, so this is the assertion that the
    /// stamp is taken before the wire and never refreshed.
    @Test("a fetch that outlives its identity is still stamped with the one it started in")
    func aFetchIsStampedWithTheGenerationItStartedIn() async throws {
        let key = MediaImageKey(uid: "stamp-start", tier: "thumb")
        let url = MediaFixture.signed(uid: "stamp-start")
        let started = identity.generation
        let transport = GatedTransport(payload: MediaFixture.png(.red))

        let inFlight = Task {
            await MediaImageLoader.uiImage(for: key, url: url, transport: transport)
        }
        await transport.waitUntilStarted()
        // The device becomes somebody else while the answer is in the air.
        identity.rotate()
        await transport.release()
        let painted = await inFlight.value

        let sent = try #require(await transport.requests.first)
        let stamp = try #require(MediaFetchGeneration.generation(of: sent))
        #expect(stamp == started, "the answer was filed under the identity it landed in")
        #expect(stamp != identity.generation)
        // And the same fetch is refused a view, which is the other half: filing it harmlessly is
        // not permission to paint it.
        #expect(painted == nil, "a photo from the account that signed out was handed to a view")
        #expect(MediaImageLoader.cachedUIImage(for: key) == nil)
    }

    /// The race the third review round found, run in the order that made it a defect: the LIVE
    /// account's answer lands first and the previous account's lands on top of it.
    ///
    /// Under a fence that removed entries by URL this was unwinnable — the two answers shared a
    /// key, so the late writer either overwrote the live picture or the fence evicted the live
    /// picture trying to stop it. They do not share a key any more, and neither branch exists.
    @Test("a stale answer landing after a live one leaves the live picture in place")
    func aStaleAnswerCannotLandOnTheLivePicture() async throws {
        let key = MediaImageKey(uid: "reverse-order", tier: "thumb")
        let url = MediaFixture.signed(uid: "reverse-order")
        let stale = GatedTransport(payload: MediaFixture.png(.red))

        let inFlight = Task {
            await MediaImageLoader.uiImage(for: key, url: url, transport: stale)
        }
        await stale.waitUntilStarted()
        identity.rotate()

        // The account now signed in asks for the same (uid, tier) — a uid is only unique within
        // one server, which is the whole reason this hurts — and its answer lands FIRST.
        let live = ScriptedTransport(payload: MediaFixture.png(.blue))
        let painted = try #require(
            await MediaImageLoader.uiImage(for: key, url: url, transport: live)
        )

        // Only now does the previous account's answer arrive.
        await stale.release()
        let stalePainted = await inFlight.value
        #expect(stalePainted == nil)

        let held = try #require(MediaImageLoader.cachedUIImage(for: key))
        #expect(held === painted, "the previous account's photo replaced the live one")
    }

    /// The other direction, and the reason this is a fence rather than a purge: a device that has
    /// not changed pays nothing for it. Two views of one photo, one request.
    @Test("a second view of the same photo in one identity never reaches the network")
    func aStableGenerationIsStillAHit() async throws {
        let key = MediaImageKey(uid: "hit-stable", tier: "thumb")
        let url = MediaFixture.signed(uid: "hit-stable")
        let transport = ScriptedTransport(payload: MediaFixture.png(.green))

        let first = try #require(
            await MediaImageLoader.uiImage(for: key, url: url, transport: transport)
        )
        let second = try #require(
            await MediaImageLoader.uiImage(for: key, url: url, transport: transport)
        )

        #expect(second === first)
        #expect(await transport.calls == 1, "a stable identity re-fetched what it already held")
        #expect(MediaImageLoader.cachedUIImage(for: key) === first)
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

    /// The decoded half of the fence, stated where nothing else can be doing the work: the entry
    /// is FILED under the generation it was stored in, so two identities cannot share a key even
    /// when they share a `(uid, tier)`.
    ///
    /// Written in the order that made this a defect — the live answer first, the previous
    /// account's afterwards. The emptying at the rotation has already happened by then and cannot
    /// help; only the key can.
    @Test("an answer from the previous identity cannot land on the current one's picture")
    func aStaleStoreCannotReachTheCurrentIdentity() throws {
        let identity = MediaIdentity()
        let store = MediaImageStore(countLimit: 8, totalCostLimit: 1 << 20, identity: identity)
        let key = MediaImageKey(uid: "reverse", tier: "thumb")
        let previous = try #require(UIImage(data: MediaFixture.png(.red)))
        let current = try #require(UIImage(data: MediaFixture.png(.blue)))
        let stale = store.generation

        identity.rotate()
        #expect(store.store(current, forKey: key, generation: store.generation))

        // The previous identity's fetch lands last, for the very same (uid, tier).
        #expect(
            !store.store(previous, forKey: key, generation: stale),
            "an answer for an identity that has ended was declared paintable"
        )
        #expect(
            store.image(forKey: key) === current,
            "the previous identity's photo replaced the current one's"
        )
    }

    /// The counterpart nobody should have to pay for: an identity that has not moved reads back
    /// exactly what it stored.
    @Test("a stable identity reads back what it stored")
    func aStableIdentityKeepsItsPictures() throws {
        let store = MediaImageStore(
            countLimit: 8,
            totalCostLimit: 1 << 20,
            identity: MediaIdentity()
        )
        let key = MediaImageKey(uid: "stable", tier: "thumb")
        let image = try #require(UIImage(data: MediaFixture.png(.green)))

        #expect(store.store(image, forKey: key, generation: store.generation))
        #expect(store.image(forKey: key) === image)
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
