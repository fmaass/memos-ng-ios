import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The machine on its own: which transition each pair of state and event produces.
///
/// The interleavings that these transitions exist to prevent are exercised through the real object
/// graph in `NativeLoginLifecycleTests`. This suite is the other half — the exhaustive one, where
/// every pair is cheap to state, including the ones no sequence of taps produces today.
@Suite("The native sign-in as a machine")
struct NativeLoginFlowTests {
    private let callback = URL(string: "https://memos.example.invalid/ios/auth/callback?code=abc")!
    private let tapped = URL(string: "memosng://auth-callback?code=abc")!

    /// Starts an attempt and hands back the machine and the attempt it minted.
    private func presenting() -> (flow: NativeLoginFlow, attempt: NativeLoginFlow.Attempt) {
        var flow = NativeLoginFlow()
        guard case .present(let attempt) = flow.receive(.presented) else {
            Issue.record("a tap on an idle sign-in did not open one")
            return (flow, NativeLoginFlow.Attempt(generation: 0))
        }
        #expect(flow.state == .presenting(attempt))
        return (flow, attempt)
    }

    @Test("a callback hands the URL over and moves on to the exchange")
    func callbackIsDelivered() {
        var (flow, attempt) = presenting()
        let effect = flow.receive(.callback(callback, .universalLink, attempt))
        #expect(effect == .deliver(callback, .universalLink, attempt))
        #expect(flow.state == .exchanging(attempt))
    }

    @Test("the second lane's copy of the same callback is ignored")
    func doubleCallbackIsIgnored() {
        var (flow, attempt) = presenting()
        _ = flow.receive(.callback(callback, .universalLink, attempt))
        #expect(flow.receive(.callback(tapped, .customScheme, attempt)) == .nothing)
        #expect(flow.state == .exchanging(attempt))
    }

    /// The failure this rebuild is about. The app cannot tell a deliberate close apart from a
    /// finished login whose callback never arrived — on the phones this was built for, the second
    /// is the likely case — so both get a sentence, and neither gets silence.
    @Test("closing the view without a callback is reported, never swallowed")
    func dismissWithoutCallbackIsVisible() {
        var (flow, attempt) = presenting()
        #expect(flow.receive(.dismissed(attempt)) == .abandon(.cancelled, attempt))
        #expect(flow.state == .failed)
        #expect(NativeLoginError.cancelled.message?.isEmpty == false)
    }

    @Test("a browser view that never came up fails with something readable")
    func viewThatNeverAppeared() {
        var (flow, attempt) = presenting()
        let effect = flow.receive(.timedOut(attempt))
        #expect(effect == .abandon(.presentationFailed(NativeLoginFlow.neverAppeared), attempt))
        #expect(flow.state == .failed)
        guard case .abandon(let error, _) = effect else {
            Issue.record("a view that never appeared did not abandon the attempt")
            return
        }
        #expect(error.message?.isEmpty == false)
    }

    @Test("the app's own dismissal after a callback is not a cancel")
    func dismissAfterTheCallbackIsNotACancel() {
        var (flow, attempt) = presenting()
        _ = flow.receive(.callback(callback, .universalLink, attempt))
        #expect(flow.receive(.dismissed(attempt)) == .nothing)
        #expect(flow.state == .exchanging(attempt))
    }

    @Test("a watchdog that fires after the answer arrived changes nothing")
    func lateWatchdog() {
        var (flow, attempt) = presenting()
        _ = flow.receive(.callback(tapped, .customScheme, attempt))
        #expect(flow.receive(.timedOut(attempt)) == .nothing)
        #expect(flow.state == .exchanging(attempt))
    }

    /// Every signal an ended attempt can still produce, aimed at the machine while a LATER attempt
    /// is on screen. All of them must do nothing: each one otherwise cancels or fails a sign-in
    /// that has nothing to do with it.
    @Test("no signal from a finished attempt touches the one that replaced it")
    func staleSignalsAreDropped() {
        var (flow, first) = presenting()
        _ = flow.receive(.dismissed(first))
        guard case .present(let second) = flow.receive(.presented) else {
            Issue.record("a retry after a cancel did not open a sign-in")
            return
        }

        #expect(flow.receive(.dismissed(first)) == .nothing)
        #expect(flow.receive(.timedOut(first)) == .nothing)
        #expect(flow.receive(.callback(callback, .universalLink, first)) == .nothing)
        #expect(flow.receive(.exchangeFinished(succeeded: true, first)) == .nothing)
        #expect(flow.state == .presenting(second), "a stale signal moved the live attempt")

        // And the live one still works.
        #expect(
            flow.receive(.callback(tapped, .customScheme, second))
                == .deliver(tapped, .customScheme, second)
        )
    }

    @Test("an attempt id is never reused, so a late signal can never look current")
    func attemptsAreNeverReused() {
        var flow = NativeLoginFlow()
        var seen: Set<NativeLoginFlow.Attempt> = []
        for _ in 0..<5 {
            guard case .present(let attempt) = flow.receive(.presented) else {
                Issue.record("a tap on a finished sign-in did not open one")
                return
            }
            #expect(seen.insert(attempt).inserted, "an attempt id came back a second time")
            _ = flow.receive(.dismissed(attempt))
        }
    }

    /// A visible browser view IS the affordance: there is nothing a second tap could add, and both
    /// alternatives are worse — two live attempts, or a failure notice over a working sign-in.
    @Test("a tap while a sign-in is on screen opens nothing")
    func aSecondTapOpensNothing() {
        var (flow, attempt) = presenting()
        #expect(flow.receive(.presented) == .nothing)
        #expect(flow.state == .presenting(attempt), "a second tap replaced the live attempt")

        _ = flow.receive(.callback(callback, .universalLink, attempt))
        #expect(flow.receive(.presented) == .nothing)
        #expect(flow.state == .exchanging(attempt), "a tap mid-exchange replaced the attempt")
    }

    @Test("a cancelled sign-in can be tried again from the same screen")
    func cancelThenRetry() {
        var (flow, first) = presenting()
        _ = flow.receive(.dismissed(first))
        #expect(flow.state == .failed)

        guard case .present(let second) = flow.receive(.presented) else {
            Issue.record("a cancelled sign-in could not be tried again")
            return
        }
        #expect(second != first)
        #expect(flow.state == .presenting(second))
    }

    @Test("the exchange's outcome is what ends the attempt", arguments: [true, false])
    func exchangeOutcomeEndsIt(_ succeeded: Bool) {
        var (flow, attempt) = presenting()
        _ = flow.receive(.callback(callback, .universalLink, attempt))
        #expect(flow.receive(.exchangeFinished(succeeded: succeeded, attempt)) == .settle(attempt))
        #expect(flow.state == (succeeded ? .done : .failed))
    }

    @Test("an outcome reported for an attempt that never started does nothing")
    func outcomeWithoutAnAttempt() {
        var flow = NativeLoginFlow()
        let ghost = NativeLoginFlow.Attempt(generation: 99)
        #expect(flow.receive(.exchangeFinished(succeeded: true, ghost)) == .nothing)
        #expect(flow.receive(.dismissed(ghost)) == .nothing)
        #expect(flow.receive(.timedOut(ghost)) == .nothing)
        #expect(flow.state == .idle)
    }

    /// The invariant, checked by walking every event out of every state rather than by trusting
    /// the presenter to remember it: an attempt that stops being on screen is always told to take
    /// its browser view down. A terminal state that left one up is a sign-in nobody can escape.
    @Test("no attempt ever stops presenting without its browser view being taken down")
    func everyTerminalTransitionTakesTheViewDown() {
        for event in everyEvent {
            var (flow, attempt) = presenting()
            let effect = flow.receive(event(attempt))
            guard flow.state.liveAttempt != attempt else {
                #expect(
                    !effect.takesTheBrowserDown,
                    "a still-presenting attempt was told to take its view down: \(effect)"
                )
                continue
            }
            #expect(
                effect.takesTheBrowserDown,
                "the attempt stopped presenting with its view still up: \(effect)"
            )
            #expect(effect.attempt == attempt, "the effect named a different attempt: \(effect)")
        }
    }

    private var everyEvent: [(NativeLoginFlow.Attempt) -> NativeLoginFlow.Event] {
        [
            { _ in .presented },
            { .callback(URL(string: "memosng://auth-callback?code=abc")!, .customScheme, $0) },
            { .dismissed($0) },
            { .timedOut($0) },
            { .exchangeFinished(succeeded: true, $0) },
            { .exchangeFinished(succeeded: false, $0) },
        ]
    }
}
