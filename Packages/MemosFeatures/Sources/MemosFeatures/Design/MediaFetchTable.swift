import Foundation
import MemosCore
import SwiftUI
import os

/// Asked for a freshly signed URL when the server refused a rendition because its signature
/// expired.
///
/// Only the screen that owns the list a picture came from can mint another URL for it, and each
/// does it its own way — a memo is read again, a library page walked, a bucket list refreshed — so
/// the loader names the attachment and leaves the how to whoever is listening.
@MainActor
protocol SignedURLRefreshing: AnyObject {
    /// The store a refresh through this refresher reaches. The cooldown is kept per owner, not per
    /// refresher: a screen builds a fresh refresher on every evaluation of its body, and two
    /// screens over one store must share that store's one refresh.
    var owner: AnyObject { get }
    func signatureExpired(uid: String)
}

extension EnvironmentValues {
    /// Who re-signs a picture this subtree shows. Nil where nobody can, and a lapsed signature is
    /// then a picture that waits for the next read of its list.
    @Entry var signedURLRefresher: (any SignedURLRefreshing)?
}

/// Every rendition fetch on the wire, and the ones waiting for a turn.
///
/// One entry per `(uid, tier, generation)`: a second view asking for a picture already on its way
/// waits for that request instead of sending its own, which is what ten tiles of one photo on a
/// remounting screen used to be — ten requests for the same bytes. At most `limit` requests are
/// out at once; the rest wait newest first, because the row that mounted last is the one the
/// reader stopped on and the ones before it have usually scrolled away.
///
/// A waiter that goes away — its row scrolled off, its task cancelled — leaves at once, and a
/// request nobody is waiting for any more is cancelled rather than left to finish for nobody.
@MainActor
final class MediaFetchTable {
    struct Key: Hashable {
        let image: MediaImageKey
        let generation: Int
    }

    /// One owner's refresh of one picture under one identity.
    struct RefreshSlot: Hashable {
        let owner: ObjectIdentifier
        let uid: String
        let generation: Int
    }

    let limit: Int
    private var flights: [Key: Flight] = [:]
    /// Newest last, and taken from the end.
    private var queued: [Flight] = []
    private var running = 0
    private var refreshed: [RefreshSlot: Date] = [:]
    /// Refreshes asked for inside their owner's cooldown, each waiting for it to end.
    private var owed: Set<RefreshSlot> = []
    private let sleep: @MainActor (TimeInterval) async -> Void
    /// The identity the loader is fetching for now; an ask about another is nobody's to answer.
    private let currentGeneration: @MainActor () -> Int

    init(
        limit: Int = MediaBudget.inFlight,
        sleep: @escaping @MainActor (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        currentGeneration: @escaping @MainActor () -> Int = { MediaImageLoader.store.generation }
    ) {
        self.limit = limit
        self.sleep = sleep
        self.currentGeneration = currentGeneration
    }

    /// How many fetches are waiting for a turn. Read by a test to know the queue's order is set.
    var waitingCount: Int { queued.count }

    /// The answer for `key`, from the fetch already out for it or from `fetch` run in its turn.
    func answer(
        _ key: Key,
        url: URL,
        fetch: @escaping @MainActor () async -> MediaImageAnswer
    ) async -> MediaImageAnswer {
        let flight = flight(for: key, url: url, fetch: fetch)
        let waiter = Waiter()
        flight.waiters.append(waiter)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter.install($0) }
        } onCancel: {
            // Answered here, synchronously, and exactly once: whichever of the flight's answer and
            // this cancellation claims the waiter first is the one it hears.
            guard waiter.deliver(.interrupted) else { return }
            Task { @MainActor in self.prune(key) }
        }
    }

    /// Asks `refresher` for a fresh URL for `uid` now, or — inside its owner's cooldown — once
    /// that cooldown ends. Returns whether it was asked now.
    ///
    /// Deferred, never dropped: a picture refused inside the cooldown still holds a URL that will
    /// never load, and nothing else is going to ask for it again.
    @discardableResult
    func refresh(
        _ key: Key,
        via refresher: (any SignedURLRefreshing)?,
        at now: Date = Date()
    ) -> Bool {
        // An answer that outlived its identity: the lists that drew it were emptied with it.
        guard let refresher, key.generation == currentGeneration() else { return false }
        // One ask per picture, whichever tier lapsed: every tier is re-signed by the same read.
        let slot = RefreshSlot(
            owner: ObjectIdentifier(refresher.owner),
            uid: key.image.uid,
            generation: key.generation
        )
        guard let last = refreshed[slot],
            now.timeIntervalSince(last) < MediaBudget.refreshCooldown
        else {
            refreshed[slot] = now
            refresher.signatureExpired(uid: slot.uid)
            return true
        }
        guard owed.insert(slot).inserted else { return false }
        let remaining = MediaBudget.refreshCooldown - now.timeIntervalSince(last)
        Task { [self] in
            await sleep(remaining)
            owed.remove(slot)
            // Checked when the ask is MADE, not when it was owed: a sign-out in between empties
            // every list that held the picture, and an ask now would reach the next account's.
            guard slot.generation == currentGeneration() else { return }
            refreshed[slot] = Date()
            refresher.signatureExpired(uid: slot.uid)
        }
        return false
    }

    /// The flight a new waiter waits on.
    ///
    /// The one already out for this key, while somebody is still waiting for it — or it is
    /// fetching this very URL and has not been cancelled — and it is not a signature already known
    /// to be spent while the asker holds another. Otherwise a new one, and the old one's waiters
    /// move to it: they asked for this picture, not for that URL, and a flight retired with them
    /// still on it would leave each of them waiting for an answer nobody will deliver.
    private func flight(
        for key: Key,
        url: URL,
        fetch: @escaping @MainActor () async -> MediaImageAnswer
    ) -> Flight {
        guard let current = flights[key] else { return begin(key, url: url, fetch: fetch) }
        let waiting = current.waiters.filter { $0.isWaiting }
        let alive =
            !waiting.isEmpty || (current.url == url && current.task?.isCancelled != true)
        let spent = current.url != url && SignedMediaURL(url: current.url).isExpired(at: Date())
        if alive, !spent { return current }
        // Taken off the old flight before it is retired, so the old flight's own answer, when its
        // transport returns, is delivered to nobody and each moved waiter hears exactly one.
        current.waiters = []
        retire(current)
        let next = begin(key, url: url, fetch: fetch)
        next.waiters = waiting
        return next
    }

    private func begin(
        _ key: Key,
        url: URL,
        fetch: @escaping @MainActor () async -> MediaImageAnswer
    ) -> Flight {
        let flight = Flight(key: key, url: url, fetch: fetch)
        flights[key] = flight
        if running < limit {
            launch(flight)
        } else {
            queued.append(flight)
        }
        return flight
    }

    private func launch(_ flight: Flight) {
        running += 1
        flight.task = Task { [self] in
            let answer = await flight.fetch()
            finish(flight, answer)
        }
    }

    /// The turn is given back when the transport RETURNS, not when the request is cancelled: a
    /// cancelled request can still be holding its connection, and the budget is about the wire.
    private func finish(_ flight: Flight, _ answer: MediaImageAnswer) {
        running -= 1
        if flights[flight.key] === flight { flights[flight.key] = nil }
        for waiter in flight.waiters { waiter.deliver(answer) }
        flight.waiters = []
        if running < limit, let next = queued.popLast() { launch(next) }
    }

    /// The flight for `key` once its last waiter left: gone from the table, and off the wire.
    private func prune(_ key: Key) {
        guard let flight = flights[key], !flight.waiters.contains(where: { $0.isWaiting })
        else { return }
        retire(flight)
    }

    /// Out of the table, and out of the queue or off the wire. Its slot is given back by `finish`
    /// when a launched flight's transport returns, and a queued one never held one.
    private func retire(_ flight: Flight) {
        if flights[flight.key] === flight { flights[flight.key] = nil }
        if let index = queued.firstIndex(where: { $0 === flight }) {
            queued.remove(at: index)
        } else {
            flight.task?.cancel()
        }
    }

    @MainActor
    private final class Flight {
        let key: Key
        let url: URL
        let fetch: @MainActor () async -> MediaImageAnswer
        var waiters: [Waiter] = []
        var task: Task<Void, Never>?

        init(key: Key, url: URL, fetch: @escaping @MainActor () async -> MediaImageAnswer) {
            self.key = key
            self.url = url
            self.fetch = fetch
        }
    }

    /// One view waiting on a flight. Its answer is claimed under a lock, so the flight's answer
    /// and a cancellation arriving on another thread cannot both resume it.
    nonisolated private final class Waiter: Sendable {
        private enum State {
            case pending
            case waiting(CheckedContinuation<MediaImageAnswer, Never>)
            case answered(MediaImageAnswer)
            case done
        }

        private let state = OSAllocatedUnfairLock<State>(uncheckedState: .pending)

        var isWaiting: Bool {
            state.withLock {
                switch $0 {
                case .pending, .waiting: true
                case .answered, .done: false
                }
            }
        }

        func install(_ continuation: CheckedContinuation<MediaImageAnswer, Never>) {
            let early: MediaImageAnswer? = state.withLock {
                guard case .answered(let answer) = $0 else {
                    $0 = .waiting(continuation)
                    return nil
                }
                $0 = .done
                return answer
            }
            if let early { continuation.resume(returning: early) }
        }

        /// Whether this call was the one that answered.
        @discardableResult
        func deliver(_ answer: MediaImageAnswer) -> Bool {
            let claimed: (CheckedContinuation<MediaImageAnswer, Never>?, Bool) = state.withLock {
                switch $0 {
                case .pending:
                    $0 = .answered(answer)
                    return (nil, true)
                case .waiting(let continuation):
                    $0 = .done
                    return (continuation, true)
                case .answered, .done:
                    return (nil, false)
                }
            }
            claimed.0?.resume(returning: answer)
            return claimed.1
        }
    }
}
