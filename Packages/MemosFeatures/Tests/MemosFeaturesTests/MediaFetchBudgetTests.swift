import Foundation
import MemosCore
import MemosOutbox
import Testing
import UIKit

@testable import MemosFeatures

/// A transport whose requests wait until they are cancelled, counting how many were.
///
/// `HeldTransport` ignores cancellation on purpose; this one is the other half of the question:
/// whether a request nobody is waiting for any more is really taken off the wire.
actor CancelWatchingTransport: MediaTransport {
    private(set) var started = 0
    private(set) var cancelled = 0

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        started += 1
        do {
            try await Task.sleep(for: .seconds(120))
        } catch {
            cancelled += 1
            throw URLError(.cancelled)
        }
        throw URLError(.timedOut)
    }
}

/// The owner of a list, as the loader sees it: it is told which picture's signature expired.
@MainActor
final class CountingRefresher: SignedURLRefreshing {
    private(set) var asked: [String] = []
    private let store: AnyObject?

    /// `store` is the list it refreshes; two refreshers over one store share its cooldown.
    init(store: AnyObject? = nil) {
        self.store = store
    }

    var owner: AnyObject { store ?? self }

    func signatureExpired(uid: String) { asked.append(uid) }
}

/// A sleep that ends when the test says so, so "when the cooldown ends" is an event, not a wait.
final class CooldownGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        stream = made.stream
        continuation = made.continuation
    }

    func open() { continuation.yield() }

    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

/// Where a test task leaves its answer, so a waiter that never hears one can be SEEN not hearing
/// it rather than hanging the case.
@MainActor
final class AnswerBox {
    var answer: MediaImageAnswer?
}

extension MediaImageLoaderTests {
    func isPicture(_ answer: MediaImageAnswer) -> Bool {
        if case .picture = answer { return true }
        return false
    }

    /// Lets every task already started reach the table before the test reads it.
    func letAsksArrive() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("ten rows asking for one picture put one request on the wire")
    func tenAsksForOneKeyAreOneRequest() async {
        let transport = HeldTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let key = MediaImageKey(uid: "coalesced", tier: "thumb")
            let url = MediaFixture.signed(uid: "coalesced")
            let asks = (0..<10).map { _ in
                Task { await MediaImageLoader.answer(for: key, url: url) }
            }
            await transport.waitUntilStarted(1)
            await letAsksArrive()
            #expect(await transport.calls == 1, "a second row sent its own request")

            await transport.releaseAll()
            var pictures = 0
            for ask in asks {
                if isPicture(await ask.value) { pictures += 1 }
            }
            #expect(pictures == 10, "a row waiting on the shared request was never answered")
            #expect(await transport.calls == 1)
        }
    }

    @Test("the seventh distinct request waits, and the last one queued goes first")
    func theBudgetQueuesNewestFirst() async {
        let transport = HeldTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            func ask(_ index: Int) -> Task<MediaImageAnswer, Never> {
                let uid = "budget-\(index)"
                return Task {
                    await MediaImageLoader.answer(
                        for: MediaImageKey(uid: uid, tier: "thumb"),
                        url: MediaFixture.signed(uid: uid)
                    )
                }
            }
            var asks = (1...MediaBudget.inFlight).map(ask)
            await transport.waitUntilStarted(MediaBudget.inFlight)

            asks.append(ask(7))
            let seventhQueued = await eventually { MediaImageLoader.flights.waitingCount == 1 }
            asks.append(ask(8))
            let eighthQueued = await eventually { MediaImageLoader.flights.waitingCount == 2 }
            #expect(seventhQueued && eighthQueued, "the requests past the budget were not queued")
            #expect(await transport.calls == MediaBudget.inFlight, "the budget let a 7th out")

            await transport.release(1)
            await transport.waitUntilStarted(MediaBudget.inFlight + 1)
            let newest = await transport.calls(matching: "budget-8/")
            #expect(newest == 1, "the newest did not go first")
            #expect(await transport.calls(matching: "budget-7/") == 0)

            await transport.releaseAll()
            for ask in asks { _ = await ask.value }
        }
    }

    @Test("a row that goes away while it is the only one waiting cancels the request")
    func theSoleWaiterLeavingCancelsTheRequest() async {
        let transport = CancelWatchingTransport()
        await withTransport(transport) {
            let key = MediaImageKey(uid: "sole-waiter", tier: "thumb")
            let url = MediaFixture.signed(uid: "sole-waiter")
            let ask = Task { await MediaImageLoader.answer(for: key, url: url) }
            let started = await eventually { await transport.started == 1 }
            #expect(started)

            ask.cancel()
            #expect(await ask.value == .interrupted)
            let cancelled = await eventually { await transport.cancelled == 1 }
            #expect(cancelled, "the request nobody waited for was left on the wire")
        }
    }

    @Test("a row that goes away beside another leaves the request to the one still waiting")
    func aWaiterLeavingBesideAnotherKeepsTheRequest() async {
        let transport = HeldTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let key = MediaImageKey(uid: "two-waiters", tier: "thumb")
            let url = MediaFixture.signed(uid: "two-waiters")
            let leaving = Task { await MediaImageLoader.answer(for: key, url: url) }
            let staying = Task { await MediaImageLoader.answer(for: key, url: url) }
            await transport.waitUntilStarted(1)
            await letAsksArrive()

            leaving.cancel()
            #expect(await leaving.value == .interrupted, "the row that left was still waiting")
            await transport.releaseAll()
            #expect(isPicture(await staying.value), "the row that stayed lost its answer")
            #expect(await transport.calls == 1)
        }
    }

    @Test("a 403 on an expired signature asks the owner once, and not again inside the cooldown")
    func anExpiredRefusalAsksForAFreshURLOnce() async {
        let transport = ScriptedTransport(payload: Data(), status: 403)
        await withTransport(transport) {
            let refresher = CountingRefresher()
            let key = MediaImageKey(uid: "lapsed", tier: "thumb")
            let url = MediaFixture.signed(uid: "lapsed", exp: 1_000_000_000)

            let first = await MediaImageLoader.answer(for: key, url: url, refresher: refresher)
            #expect(first == .signatureExpired)
            #expect(refresher.asked == ["lapsed"])

            let second = await MediaImageLoader.answer(for: key, url: url, refresher: refresher)
            #expect(second == .signatureExpired)
            #expect(refresher.asked == ["lapsed"], "the owner was asked again inside the cooldown")
        }
    }

    @Test("a queued request replaced for a fresh URL hands its waiter to the replacement")
    func aReplacedQueuedFlightHandsItsWaitersOn() async {
        let transport = HeldTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            var fillers: [Task<MediaImageAnswer, Never>] = []
            for index in 1...MediaBudget.inFlight {
                let uid = "fill-\(index)"
                fillers.append(
                    Task {
                        await MediaImageLoader.answer(
                            for: MediaImageKey(uid: uid, tier: "thumb"),
                            url: MediaFixture.signed(uid: uid)
                        )
                    })
            }
            await transport.waitUntilStarted(MediaBudget.inFlight)

            let key = MediaImageKey(uid: "requeued", tier: "thumb")
            let lapsed = MediaFixture.signed(uid: "requeued", exp: 1_000_000_000, sig: "old0")
            let fresh = MediaFixture.signed(uid: "requeued", sig: "new0")
            let first = AnswerBox()
            let firstAsk = Task {
                first.answer = await MediaImageLoader.answer(for: key, url: lapsed)
            }
            let queued = await eventually { MediaImageLoader.flights.waitingCount == 1 }
            #expect(queued, "precondition: the lapsed request is waiting for a turn")
            let second = Task { await MediaImageLoader.answer(for: key, url: fresh) }
            await letAsksArrive()

            await transport.releaseAll()
            #expect(isPicture(await second.value))
            let heard = await eventually { first.answer != nil }
            #expect(heard, "the first waiter was left on a flight nobody will answer")
            #expect(first.answer.map(isPicture) == true, "the first waiter did not get the picture")
            #expect(await transport.calls(matching: "sig=old0") == 0, "the spent URL was sent")
            #expect(MediaImageLoader.flights.waitingCount == 0)
            firstAsk.cancel()
            for filler in fillers { _ = await filler.value }
        }
    }

    @Test("a running request replaced for a fresh URL hands its waiter to the replacement")
    func aReplacedRunningFlightHandsItsWaitersOn() async {
        let transport = HeldTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let key = MediaImageKey(uid: "rerun", tier: "thumb")
            let lapsed = MediaFixture.signed(uid: "rerun", exp: 1_000_000_000, sig: "old1")
            let fresh = MediaFixture.signed(uid: "rerun", sig: "new1")
            let first = AnswerBox()
            let firstAsk = Task {
                first.answer = await MediaImageLoader.answer(for: key, url: lapsed)
            }
            await transport.waitUntilStarted(1)
            let second = Task { await MediaImageLoader.answer(for: key, url: fresh) }
            await transport.waitUntilStarted(2)

            await transport.release(matching: "sig=new1")
            #expect(isPicture(await second.value))
            let heard = await eventually { first.answer != nil }
            #expect(heard, "the first waiter stayed on the spent URL's request")
            #expect(first.answer.map(isPicture) == true, "the first waiter did not get the picture")

            await transport.releaseAll()
            firstAsk.cancel()
            // The spent request's return gives its slot back: a full budget still goes out at once.
            let asks = (1...MediaBudget.inFlight).map { index in
                Task {
                    await MediaImageLoader.answer(
                        for: MediaImageKey(uid: "after-\(index)", tier: "thumb"),
                        url: MediaFixture.signed(uid: "after-\(index)")
                    )
                }
            }
            for ask in asks { #expect(isPicture(await ask.value)) }
            #expect(MediaImageLoader.flights.waitingCount == 0)
        }
    }

    @Test("a refusal answered for a second store inside the first one's cooldown asks that store")
    func anotherOwnersRefreshIsNotSwallowed() async {
        let transport = ScriptedTransport(payload: Data(), status: 403)
        await withTransport(transport) {
            let timeline = CountingRefresher(store: NSObject())
            let library = CountingRefresher(store: NSObject())
            let sameTimeline = CountingRefresher(store: timeline.owner)
            let key = MediaImageKey(uid: "shared", tier: "thumb")
            let url = MediaFixture.signed(uid: "shared", exp: 1_000_000_000)

            _ = await MediaImageLoader.answer(for: key, url: url, refresher: timeline)
            _ = await MediaImageLoader.answer(for: key, url: url, refresher: library)
            _ = await MediaImageLoader.answer(for: key, url: url, refresher: sameTimeline)

            #expect(timeline.asked == ["shared"])
            #expect(library.asked == ["shared"], "the second store's recovery was swallowed")
            #expect(sameTimeline.asked.isEmpty, "one store was asked twice inside its cooldown")
        }
    }

    @Test("a refusal inside the cooldown is asked for when the cooldown ends, not dropped")
    func aRefreshInsideTheCooldownRunsWhenItEnds() async {
        let gate = CooldownGate()
        MediaImageLoader.flights = MediaFetchTable(sleep: { _ in await gate.wait() })
        let transport = ScriptedTransport(payload: Data(), status: 403)
        await withTransport(transport) {
            let refresher = CountingRefresher()
            let key = MediaImageKey(uid: "owed", tier: "thumb")
            let url = MediaFixture.signed(uid: "owed", exp: 1_000_000_000)

            _ = await MediaImageLoader.answer(for: key, url: url, refresher: refresher)
            _ = await MediaImageLoader.answer(for: key, url: url, refresher: refresher)
            _ = await MediaImageLoader.answer(for: key, url: url, refresher: refresher)
            #expect(refresher.asked == ["owed"], "the cooldown let a second ask straight through")

            gate.open()
            let asked = await eventually { refresher.asked.count == 2 }
            #expect(asked, "the refusal inside the cooldown was dropped")
            await letAsksArrive()
            #expect(refresher.asked == ["owed", "owed"], "the owed ask ran more than once")
        }
    }

    @Test("a 403 on a signature still in date is a failure, and nobody is asked")
    func aRefusalOfAValidSignatureIsUnavailable() async {
        let transport = ScriptedTransport(payload: Data(), status: 403)
        await withTransport(transport) {
            let refresher = CountingRefresher()
            let key = MediaImageKey(uid: "refused", tier: "thumb")
            let url = MediaFixture.signed(uid: "refused")

            let answer = await MediaImageLoader.answer(for: key, url: url, refresher: refresher)
            #expect(answer == .unavailable)
            #expect(refresher.asked.isEmpty)
        }
    }
}
