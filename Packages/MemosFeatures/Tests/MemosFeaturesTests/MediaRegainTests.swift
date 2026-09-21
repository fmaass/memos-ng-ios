import Foundation
import MemosCore
import MemosOutbox
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// A transport that holds its FIRST request until the case lets it through, records every url it
/// was asked for, and then either answers with a picture or does not.
///
/// The hold is what makes the case expressible at all: the signal under test arrives while a fetch
/// is outstanding, and there is no such moment unless a fetch can be made to wait.
actor RegainTransport: MediaTransport {
    /// Nil is the answer under test — one that is no picture, and not an abandonment.
    private let payload: Data?
    private(set) var requested: [URL] = []
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(payload: Data? = nil) {
        self.payload = payload
    }

    var count: Int { requested.count }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiting = releaseWaiters
        releaseWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        let url = request.url ?? URL(string: "https://memos.example.invalid/")!
        let isFirst = requested.isEmpty
        requested.append(url)
        if isFirst {
            started = true
            let waiting = startWaiters
            startWaiters = []
            for waiter in waiting { waiter.resume() }
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }
        guard let payload else { throw URLError(.timedOut) }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        return (payload, response)
    }
}

/// Waits for what a view on screen does on its own turn, and gives up rather than hanging.
private func awaitUntil(tries: Int = 80, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<tries {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return await condition()
}

extension MediaImageLoaderTests {
    /// The tile half of the contract: a route regain arriving while a tile still waits on a fetch
    /// that will never answer must make that tile ask again once that fetch fails.
    @Test("a signal that arrives while a tile is fetching is answered when that fetch fails")
    func aTileAsksAgainWhenTheFetchASignalArrivedDuringFails() async {
        let transport = RegainTransport()
        await withTransport(transport) {
            let window = hostedTile(for: MediaFixture.attachment(uid: "regain-tile-fails"))
            #expect(await awaitUntil { await transport.count == 1 }, "the tile never fetched")

            MediaRetrySignal.shared.publish()
            await transport.release()

            #expect(
                await awaitUntil { await transport.count == 2 },
                "the tile never asked again after the fetch the signal arrived during failed"
            )
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// The control the case above is worth nothing without: the same signal, arriving during a
    /// fetch that ANSWERS, asks for nothing — the picture is on screen.
    @Test("a signal that arrives while a tile is fetching asks nothing when that fetch succeeds")
    func aTileAsksNothingWhenTheFetchASignalArrivedDuringSucceeds() async {
        let transport = RegainTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let window = hostedTile(for: MediaFixture.attachment(uid: "regain-tile-answers"))
            #expect(await awaitUntil { await transport.count == 1 }, "the tile never fetched")

            MediaRetrySignal.shared.publish()
            await transport.release()

            #expect(
                await awaitUntil { await transport.count > 1 } == false,
                "the tile asked again for a picture it had just been given"
            )
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}

/// The same rule at the other consumer, through the page's own transport rather than the installed
/// one — the full-screen still is the other production completion path.
@MainActor
@Suite("A full-screen still and a signal that arrives while it is fetching")
struct MediaViewerRegainTests {
    @Test("a signal that arrives while a still is fetching is answered when that fetch fails")
    func theStillAsksAgainWhenTheFetchASignalArrivedDuringFails() async throws {
        let attachment = MediaViewerPageTests.image("regain-still-fails")
        let page = try #require(MediaViewerPresentation.pages(for: [attachment]).first)
        let transport = RegainTransport()
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(
            rootView: MediaViewerPage(
                page: page,
                onHoldsChange: { _ in },
                player: nil,
                play: {},
                cache: URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil),
                transport: transport
            )
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        #expect(await awaitUntil { await transport.count == 1 }, "the still never fetched")

        MediaRetrySignal.shared.publish()
        await transport.release()

        #expect(
            await awaitUntil { await transport.count == 2 },
            "the still never asked again after the fetch the signal arrived during failed"
        )
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// What a signal arriving DURING a fetch does to the load that was already out — recorded where it
/// is refused, consumed where that fetch answers, and cleared wherever it cannot be.
///
/// Every vector ends the fetch through `settle(_:for:serial:)` with the serial the claim holds,
/// because that is the only path a view really takes: poking `askAgain` afterwards would assert
/// the test's own idea of the sequence instead of the loader's.
@MainActor
@Suite("A signal held through a fetch")
struct HeldAskTests {
    private static let key = MediaImageKey(uid: "held-ask", tier: "thumb")

    @Test("a signal that arrives while fetching is answered when the fetch has no picture")
    func aFailedFetchConsumesTheHeldSignal() {
        var load = PictureLoad()
        let serial = load.claim()

        let refused = load.askAgain(showing: false)
        #expect(refused == false, "a fetch is out; the ask is refused")

        let settled = load.settle(.unavailable, for: Self.key, serial: serial)
        #expect(settled.applied)
        #expect(settled.asksAgain, "the signal refused during the fetch was lost")
        #expect(load.failedKey == Self.key, "the answer still failed the picture")
    }

    @Test("a signal that arrives while fetching asks for nothing when the picture arrives")
    func aSuccessfulFetchClearsTheHeldSignal() {
        var load = PictureLoad()
        let serial = load.claim()
        load.askAgain(showing: false)

        let settled = load.settle(.picture(UIImage()), for: Self.key, serial: serial)
        #expect(settled.applied)
        #expect(settled.asksAgain == false, "a picture that arrived was asked for again")
    }

    @Test("two signals during one fetch are one attempt")
    func twoSignalsDuringOneFetchAreOneAsk() {
        var load = PictureLoad()
        let serial = load.claim()
        load.askAgain(showing: false)
        load.askAgain(showing: false)

        let consumed = load.settle(.unavailable, for: Self.key, serial: serial)
        #expect(consumed.asksAgain)
        // The consume is what the view acts on, and there is only ever one of them.
        let next = load.claim()
        let again = load.settle(.unavailable, for: Self.key, serial: next)
        #expect(again.asksAgain == false)
    }

    @Test("a claim that ends with no answer at all holds nothing for the next fetch")
    func anUnsettledClaimHoldsNothing() {
        var load = PictureLoad()
        let abandoned = load.claim()
        load.askAgain(showing: false)

        load.release(abandoned)

        let next = load.claim()
        let settled = load.settle(.unavailable, for: Self.key, serial: next)
        #expect(
            settled.asksAgain == false,
            "a signal held through a fetch that never answered outlived it"
        )
    }

    @Test("a signal that arrives while nothing is fetching asks at once, as it always did")
    func aSignalWithNothingOnTheWireAsksAtOnce() {
        var load = PictureLoad()

        let asked = load.askAgain(showing: false)
        #expect(asked)
        #expect(load.attempt == 1)
    }

    @Test("a superseded fetch's answer cannot consume the signal the live one is holding")
    func onlyTheClaimHolderConsumes() {
        var load = PictureLoad()
        let superseded = load.claim()
        let live = load.claim()
        load.askAgain(showing: false)

        let stale = load.settle(.unavailable, for: Self.key, serial: superseded)
        #expect(stale.asksAgain == false)
        let owner = load.settle(.unavailable, for: Self.key, serial: live)
        #expect(owner.asksAgain)
    }

    /// A view that is SHOWING its picture is owed nothing, so there is nothing to remember.
    @Test("a signal to a view that already has its picture is remembered by nothing")
    func aShowingViewHoldsNothing() {
        var load = PictureLoad()
        let serial = load.claim()

        let refused = load.askAgain(showing: true)
        #expect(refused == false)

        let settled = load.settle(.unavailable, for: Self.key, serial: serial)
        #expect(settled.asksAgain == false)
    }
}
