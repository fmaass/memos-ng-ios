import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The sign-in's outcomes, all of them, without a device.
///
/// A live `SFSafariViewController` cannot be driven from a test — the tap that proves it is on a
/// phone. What CAN be made deterministic is everything the presenter decides around it, and that
/// is where the failures live: a browser view that never came up, a callback that arrived on both
/// lanes at once, a person who closed the view, a cancel that has to leave the screen ready to try
/// again. Each of those was, at some point, a button that appeared to do nothing.
@Suite("The native sign-in as a machine")
struct NativeLoginFlowTests {
    private let callback = URL(string: "https://memos.example.invalid/ios/auth/callback?code=abc")!
    private let tapped = URL(string: "memosng://auth-callback?code=abc")!

    private func presenting() -> NativeLoginFlow {
        var flow = NativeLoginFlow()
        #expect(flow.receive(.presented) == .nothing)
        #expect(flow.state == .presenting)
        return flow
    }

    @Test("a callback hands the URL over and moves on to the exchange")
    func callbackIsDelivered() {
        var flow = presenting()
        let effect = flow.receive(.callback(callback, .universalLink))
        #expect(effect == .deliver(callback, .universalLink))
        #expect(flow.state == .exchanging)
    }

    /// Both lanes can fire for one sign-in: the page redirects to the https callback AND offers
    /// the tap-to-return link, and a person who taps after the redirect landed sends the same
    /// login back twice. The second one must do nothing at all — the continuation behind it has
    /// already been resumed, and resuming one twice is a crash.
    @Test("the second lane's copy of the same callback is ignored")
    func doubleCallbackIsIgnored() {
        var flow = presenting()
        _ = flow.receive(.callback(callback, .universalLink))
        #expect(flow.receive(.callback(tapped, .customScheme)) == .nothing)
        #expect(flow.state == .exchanging)
    }

    /// The failure this rebuild is about. The app cannot tell a deliberate close apart from a
    /// finished login whose callback never arrived — on the phones this was built for, the second
    /// one is the likely case — so both get a sentence, and neither gets silence.
    @Test("closing the view without a callback is reported, never swallowed")
    func dismissWithoutCallbackIsVisible() {
        var flow = presenting()
        #expect(flow.receive(.dismissed) == .abandon(.cancelled))
        #expect(flow.state == .failed)
        #expect(NativeLoginError.cancelled.message?.isEmpty == false)
    }

    @Test("a browser view that never came up fails with something readable")
    func viewThatNeverAppeared() {
        var flow = presenting()
        let effect = flow.receive(.timedOut)
        #expect(effect == .abandon(.presentationFailed(NativeLoginFlow.neverAppeared)))
        #expect(flow.state == .failed)
        guard case .abandon(let error) = effect else {
            Issue.record("a view that never appeared did not abandon the attempt")
            return
        }
        #expect(error.message?.isEmpty == false)
    }

    /// The app takes the browser view down itself once a callback arrives. If the delegate reports
    /// that as a close — it does not today, and a future iOS may — it must not be read as a person
    /// cancelling a sign-in that in fact succeeded.
    @Test("the app's own dismissal after a callback is not a cancel")
    func dismissAfterTheCallbackIsNotACancel() {
        var flow = presenting()
        _ = flow.receive(.callback(callback, .universalLink))
        #expect(flow.receive(.dismissed) == .nothing)
        #expect(flow.state == .exchanging)
    }

    @Test("a watchdog that fires after the answer arrived changes nothing")
    func lateWatchdog() {
        var flow = presenting()
        _ = flow.receive(.callback(tapped, .customScheme))
        #expect(flow.receive(.timedOut) == .nothing)
        #expect(flow.state == .exchanging)
    }

    @Test("a cancelled sign-in can be tried again from the same screen")
    func cancelThenRetry() {
        var flow = presenting()
        _ = flow.receive(.dismissed)
        #expect(flow.state == .failed)

        #expect(flow.receive(.presented) == .nothing)
        #expect(flow.state == .presenting)
        #expect(flow.receive(.callback(tapped, .customScheme)) == .deliver(tapped, .customScheme))
    }

    /// The machine may never be the reason a tap does nothing, whatever it thinks is happening —
    /// an exchange whose outcome never came back would otherwise wedge the screen for good, which
    /// is the exact symptom this replaced.
    @Test(
        "a tap is honoured from every state there is",
        arguments: [
            NativeLoginFlow.State.idle, .presenting, .exchanging, .done, .failed,
        ]
    )
    func aTapIsNeverIgnored(_ start: NativeLoginFlow.State) {
        var flow = NativeLoginFlow()
        switch start {
        case .idle:
            break
        case .presenting:
            _ = flow.receive(.presented)
        case .exchanging:
            _ = flow.receive(.presented)
            _ = flow.receive(.callback(callback, .universalLink))
        case .done:
            _ = flow.receive(.presented)
            _ = flow.receive(.callback(callback, .universalLink))
            _ = flow.receive(.exchangeFinished(succeeded: true))
        case .failed:
            _ = flow.receive(.presented)
            _ = flow.receive(.dismissed)
        }
        #expect(flow.state == start)

        #expect(flow.receive(.presented) == .nothing)
        #expect(flow.state == .presenting)
    }

    @Test("the exchange's outcome is what ends the attempt", arguments: [true, false])
    func exchangeOutcomeEndsIt(_ succeeded: Bool) {
        var flow = presenting()
        _ = flow.receive(.callback(callback, .universalLink))
        #expect(flow.receive(.exchangeFinished(succeeded: succeeded)) == .settle)
        #expect(flow.state == (succeeded ? .done : .failed))
    }

    @Test("an outcome reported for an attempt that never started does nothing")
    func outcomeWithoutAnAttempt() {
        var flow = NativeLoginFlow()
        #expect(flow.receive(.exchangeFinished(succeeded: true)) == .nothing)
        #expect(flow.receive(.dismissed) == .nothing)
        #expect(flow.receive(.timedOut) == .nothing)
        #expect(flow.state == .idle)
    }
}

/// The seam between a URL the app was opened with and the sign-in waiting for one.
@Suite("The sign-in's callback inbox")
struct NativeLoginCallbackInboxTests {
    private let callback = URL(string: "memosng://auth-callback?code=abc")!
    private let unrelated = URL(string: "https://memos.example.invalid/m/abc123")!

    @Test("a waiting sign-in is offered the URL and takes its own")
    func theWaiterClaimsItsCallback() {
        let inbox = NativeLoginCallbackInbox()
        let seen = Recorder()
        inbox.waitForCallback { url in
            seen.record(url)
            return url.scheme == "memosng"
        }

        #expect(inbox.deliver(callback))
        #expect(seen.urls == [callback])
    }

    /// Every URL the app opens for any reason passes through here. One of them resolving a sign-in
    /// that is waiting for a credential would be a sign-in finished by something that is not one.
    @Test("a URL the sign-in does not recognise is refused, not acted on")
    func anUnrelatedURLIsRefused() {
        let inbox = NativeLoginCallbackInbox()
        inbox.waitForCallback { $0.scheme == "memosng" }

        #expect(!inbox.deliver(unrelated))
    }

    @Test("with nothing waiting, nothing claims anything")
    func nobodyWaiting() {
        let inbox = NativeLoginCallbackInbox()
        #expect(!inbox.deliver(callback))
    }

    @Test("a sign-in that is over stops being offered URLs")
    func stopWaiting() {
        let inbox = NativeLoginCallbackInbox()
        let seen = Recorder()
        inbox.waitForCallback { url in
            seen.record(url)
            return true
        }
        #expect(inbox.deliver(callback))
        inbox.stopWaiting()

        #expect(!inbox.deliver(callback))
        #expect(seen.urls.count == 1, "a finished sign-in was still being offered callbacks")
    }
}

/// What the inbox handed over, in order.
@MainActor
private final class Recorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}
