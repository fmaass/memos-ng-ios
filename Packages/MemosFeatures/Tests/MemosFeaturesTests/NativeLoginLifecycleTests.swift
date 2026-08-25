import Foundation
import MemosCore
import Testing
import UIKit

@testable import MemosFeatures

/// The sign-in driven as a whole — presenter, inbox and machine composed exactly as the app
/// composes them — because the bugs this suite exists for are not in any single step.
///
/// Each of the three below is an INTERLEAVING: a signal from an attempt that has ended arriving
/// after the next attempt has begun. A browser view closing, a watchdog firing and a second tap
/// are all things the person can produce in a couple of seconds, and each of them used to reach
/// across into a sign-in it had nothing to do with. None of them is reachable by handing events to
/// the machine by hand, which is why these drive the real object graph through the one seam a test
/// can hold: the browser view.
@Suite("The sign-in's lifecycle, composed")
struct NativeLoginLifecycleTests {
    private let authorizeURL = URL(string: "https://memos.example.invalid/api/auth/login")!
    private let callbackURL = URL(string: "memosng://auth-callback?code=handoff-1")!
    /// The callback's own address with the query taken off it — what iOS hands the browser view's
    /// redirect delegate, and what a sign-in must not be resolved by. It is on a lane
    /// (`NativeLoginReturn.lane` calls it the universal-link one, deliberately: which lane a URL
    /// is on and what is written on it are separate questions) and it carries no answer at all.
    private let strippedRedirectURL = URL(
        string: "https://memos.example.invalid/ios/auth/callback"
    )!
    /// The same emptiness on the lane every sign-in in this deployment actually comes back on.
    private let strippedTapURL = URL(string: "memosng://auth-callback")!
    private let host = "memos.example.invalid"
    private let path = "/ios/auth/callback"

    /// Lets the MainActor run everything that is already queued. The presenter does its work
    /// synchronously up to the continuation, so this is enough to see a browser view appear.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func harness(watchdog: Duration = .seconds(30)) -> LoginHarness {
        LoginHarness(watchdog: watchdog)
    }

    private func signIn(_ harness: LoginHarness) -> Task<URL, any Error> {
        Task { [presenter = harness.presenter] in
            try await presenter.authenticate(
                authorizeURL: authorizeURL,
                callbackHost: host,
                callbackPath: path
            )
        }
    }

    /// INTERLEAVING 1. Cancel a sign-in, start another, and the first one's browser view reports
    /// its close a moment later — a dismissal animation finishing, a delegate call landing after
    /// the teardown. Unfenced, that close cancels the sign-in the person is now looking at.
    @Test("a dead attempt's browser closing does not cancel the sign-in that replaced it")
    func staleCloseCannotCancelTheNextAttempt() async throws {
        let harness = harness()
        let first = signIn(harness)
        await settle()
        let browserA = try #require(harness.browsers.first)

        browserA.closedByPerson()
        await settle()
        await #expect(throws: NativeLoginError.self) { try await first.value }

        let second = signIn(harness)
        await settle()
        #expect(harness.browsers.count == 2, "the retry did not open a sign-in of its own")
        let browserB = try #require(harness.browsers.last)

        // A's browser, already torn down, reports its close now.
        browserA.closedByPerson()
        await settle()

        #expect(
            browserB.dismissCount == 0,
            "a dead attempt's browser closing tore down the live sign-in's view"
        )
        #expect(
            harness.inbox.waitingFor != nil,
            "the live sign-in stopped waiting for its callback"
        )
        #expect(
            harness.inbox.deliver(callbackURL),
            "the live sign-in could not claim its own callback"
        )
        #expect(try await second.value == callbackURL)
    }

    /// INTERLEAVING 2. A watchdog is the signal most likely to outlive its attempt: cancel a
    /// sign-in and start another inside the watchdog's window and the first one's timer is still
    /// coming. Unfenced, it reads whatever attempt is live when it fires and fails THAT one — a
    /// sign-in killed a fraction of a second after opening, by a timer belonging to a sign-in the
    /// person already dismissed.
    @Test("a dead attempt's watchdog does not fail the sign-in that replaced it")
    func staleWatchdogCannotFailTheNextAttempt() async throws {
        let harness = harness(watchdog: .milliseconds(200))
        harness.appearsOnPresent = false
        let first = signIn(harness)
        await settle()
        let browserA = try #require(harness.browsers.first)
        browserA.closedByPerson()
        await settle()
        await #expect(throws: NativeLoginError.self) { try await first.value }

        // Start the replacement well inside A's watchdog window, still slow to appear.
        try await Task.sleep(for: .milliseconds(120))
        let second = signIn(harness)
        await settle()
        let browserB = try #require(harness.browsers.last)

        // Past A's watchdog (t=200ms), comfortably short of B's own (t=320ms).
        try await Task.sleep(for: .milliseconds(140))
        #expect(!second.isCancelled)
        #expect(
            browserB.dismissCount == 0,
            "a dead attempt's watchdog tore down the live sign-in's view"
        )

        // B's view arrives before its own watchdog, so B passes it on its own merits.
        browserB.isOnScreen = true
        try await Task.sleep(for: .milliseconds(160))
        #expect(
            harness.inbox.deliver(callbackURL),
            "the live sign-in was failed by another's timer"
        )
        #expect(try await second.value == callbackURL)
    }

    /// INTERLEAVING 3. A second tap while the browser view is already up. There must never be two
    /// live attempts, and the second tap must not be reported as a failure: the sign-in in front
    /// of the person is working, and an error notice over it is a lie about a sign-in that is
    /// about to succeed.
    @Test("a second tap neither opens a second sign-in nor reports a failure")
    func aSecondTapIsIgnored() async throws {
        let harness = harness()
        let first = signIn(harness)
        await settle()
        #expect(harness.browsers.count == 1)

        do {
            _ = try await harness.presenter.authenticate(
                authorizeURL: authorizeURL,
                callbackHost: host,
                callbackPath: path
            )
            Issue.record("a second tap opened a second sign-in")
        } catch let error as NativeLoginError {
            #expect(
                error.message == nil,
                "an impatient second tap painted a failure over a live sign-in"
            )
        }
        await settle()

        #expect(harness.browsers.count == 1, "a second tap opened a second browser view")
        #expect(
            harness.browsers[0].dismissCount == 0,
            "a second tap took the live sign-in's view down"
        )

        #expect(harness.inbox.deliver(callbackURL))
        #expect(try await first.value == callbackURL)
    }

    /// The ordinary path, so the three above are read as fences rather than as the whole story.
    @Test("a callback delivered to the live attempt signs in and takes the view down")
    func theHappyPath() async throws {
        let harness = harness()
        let attempt = signIn(harness)
        await settle()
        let browser = try #require(harness.browsers.first)
        #expect(browser.presentCount == 1)

        #expect(harness.inbox.deliver(callbackURL))
        #expect(try await attempt.value == callbackURL)
        #expect(browser.dismissCount == 1, "the browser view was left on screen")
        #expect(harness.inbox.waitingFor == nil, "a finished sign-in left its inbox entry behind")
    }

    /// Both lanes fire for one sign-in: the page redirects to the https callback AND offers the
    /// tap-to-return link. The second one must resolve nothing — the continuation behind it has
    /// been resumed, and resuming one twice is a crash.
    @Test("the second lane's copy of the same callback is refused, not acted on twice")
    func theSecondLaneIsRefused() async throws {
        let harness = harness()
        let attempt = signIn(harness)
        await settle()

        #expect(harness.inbox.deliver(callbackURL))
        _ = try await attempt.value
        #expect(!harness.inbox.deliver(callbackURL), "a resumed sign-in claimed a second callback")
    }

    /// THE FIELD SEQUENCE. Signing in a SECOND time is not the first time again: the household
    /// sign-on cookie is still in the browser view's own storage, so nobody types anything and
    /// nobody taps anything. Login, authorize, the BFF's callback and the page that ends it are
    /// all redirects of the FIRST load, and iOS reports each of them on the browser view's
    /// redirect delegate — with the query REMOVED, which is the platform's own rule for that
    /// delegate and not something an app can opt out of.
    ///
    /// What arrives is therefore the callback's address carrying nothing, while the sign-in's
    /// entire answer is in the query that was taken off it. Acted on, it ends the attempt with a
    /// callback that has no code in it — `NativeLogin.callback(from:)` reads exactly this shape
    /// as `.malformed` (`NativeLoginTests.readsMalformed`) — so the person is told the sign-in
    /// came back incomplete, and the real page, which the server has already rendered with a
    /// handoff code on it, arrives a moment later with nobody waiting for it.
    ///
    /// So the echo must resolve nothing, and the sign-in must still be there to take the real
    /// callback when it comes.
    @Test("a query-stripped redirect echo leaves the sign-in waiting for the real callback")
    func aStrippedRedirectEchoLeavesTheAttemptWaiting() async throws {
        let harness = harness()
        let attempt = signIn(harness)
        await settle()
        let browser = try #require(harness.browsers.first)

        #expect(
            URLComponents(url: strippedRedirectURL, resolvingAgainstBaseURL: false)?.queryItems
                == nil,
            "the fixture is not the query-stripped address the field failure is about"
        )
        browser.redirectedWhileLoading(to: strippedRedirectURL)
        await settle()

        #expect(
            harness.inbox.waitingFor != nil,
            "a query-stripped echo ended the sign-in that was still waiting for its callback"
        )
        #expect(browser.dismissCount == 0, "a query-stripped echo took the sign-in's view down")

        // The real callback arrives after it, which is the order the device and the server logs
        // both show, and it is the one that signs in.
        #expect(
            harness.inbox.deliver(callbackURL),
            "the sign-in could no longer claim the real callback"
        )
        #expect(try await attempt.value == callbackURL)
        #expect(browser.dismissCount == 1, "the browser view was left on screen")
    }

    /// The same emptiness on the delivery path the app actually signs in on. A URL the app is
    /// opened with reaches the waiting sign-in through the inbox, and one that is on the lane but
    /// carries neither a code nor a reason is an echo of the callback page rather than its
    /// answer: refused, and the sign-in left waiting for the one that has something on it.
    @Test("a query-less URL delivered to the inbox leaves the sign-in waiting")
    func aQueryLessURLOnTheInboxLeavesTheAttemptWaiting() async throws {
        let harness = harness()
        let attempt = signIn(harness)
        await settle()
        let browser = try #require(harness.browsers.first)

        #expect(
            !harness.inbox.deliver(strippedTapURL),
            "a URL with no code and no reason on it was claimed as the sign-in's callback"
        )
        #expect(
            harness.inbox.waitingFor != nil,
            "a query-less URL ended the sign-in that was still waiting for its callback"
        )
        #expect(browser.dismissCount == 0, "a query-less URL took the sign-in's view down")

        #expect(
            harness.inbox.deliver(callbackURL),
            "the sign-in could no longer claim the real callback"
        )
        #expect(try await attempt.value == callbackURL)
    }
}

/// The presenter, the inbox and the machine wired the way the app wires them, with the browser
/// view replaced by something a test can open, close and time.
@MainActor
private final class LoginHarness {
    let inbox = NativeLoginCallbackInbox()
    private(set) var browsers: [FakeLoginBrowser] = []
    /// Whether a presented browser view reports itself on screen. `false` is the failure the
    /// watchdog exists to catch.
    var appearsOnPresent = true
    private(set) var presenter: SafariLoginPresenter!

    init(watchdog: Duration) {
        presenter = SafariLoginPresenter(
            host: { UIViewController() },
            inbox: inbox,
            watchdog: watchdog,
            makeBrowser: { [unowned self] url in
                let browser = FakeLoginBrowser(url: url, appearsOnPresent: self.appearsOnPresent)
                self.browsers.append(browser)
                return browser
            }
        )
    }
}

/// A browser view that does exactly what it is told and remembers what was done to it.
@MainActor
private final class FakeLoginBrowser: LoginBrowser {
    var onClose: (() -> Void)?
    var onRedirect: ((URL) -> Void)?
    var onInitialLoad: ((Bool) -> Void)?

    let url: URL
    private let appearsOnPresent: Bool
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    var isOnScreen = false

    init(url: URL, appearsOnPresent: Bool) {
        self.url = url
        self.appearsOnPresent = appearsOnPresent
    }

    func present(from host: UIViewController) {
        presentCount += 1
        isOnScreen = appearsOnPresent
    }

    func dismiss() {
        dismissCount += 1
        isOnScreen = false
    }

    /// The person swiped it away, or tapped Cancel.
    func closedByPerson() {
        onClose?()
    }

    /// The browser followed a redirect while loading its first page. On the device this is
    /// `safariViewController(_:initialLoadDidRedirectTo:)`, and the URL it carries has had its
    /// query removed by iOS before the app ever sees it.
    func redirectedWhileLoading(to url: URL) {
        onRedirect?(url)
    }
}

/// The seam between a URL the app was opened with and the sign-in waiting for one.
@Suite("The sign-in's callback inbox")
struct NativeLoginCallbackInboxTests {
    private let callback = URL(string: "memosng://auth-callback?code=abc")!
    private let unrelated = URL(string: "https://memos.example.invalid/m/abc123")!
    private let first = NativeLoginFlow.Attempt(generation: 1)
    private let second = NativeLoginFlow.Attempt(generation: 2)

    @Test("a waiting sign-in is offered the URL and takes its own")
    func theWaiterClaimsItsCallback() {
        let inbox = NativeLoginCallbackInbox()
        inbox.waitForCallback(for: first) { $0.scheme == "memosng" }

        #expect(inbox.waitingFor == first)
        #expect(inbox.deliver(callback))
    }

    /// Every URL the app opens for any reason passes through here. One of them resolving a sign-in
    /// that is waiting for a credential would be a sign-in finished by something that is not one.
    @Test("a URL the sign-in does not recognise is refused, not acted on")
    func anUnrelatedURLIsRefused() {
        let inbox = NativeLoginCallbackInbox()
        inbox.waitForCallback(for: first) { $0.scheme == "memosng" }

        #expect(!inbox.deliver(unrelated))
    }

    @Test("with nothing waiting, nothing claims anything")
    func nobodyWaiting() {
        let inbox = NativeLoginCallbackInbox()
        #expect(!inbox.deliver(callback))
        #expect(inbox.waitingFor == nil)
    }

    /// The fence on the teardown side. An attempt that ends AFTER its replacement has registered
    /// would otherwise unregister the live one's entry, and the sign-in the person is looking at
    /// would quietly stop being able to receive its own callback.
    @Test("a finished attempt cannot unregister the entry of the one that replaced it")
    func aDeadAttemptCannotUnregisterTheLiveOne() {
        let inbox = NativeLoginCallbackInbox()
        inbox.waitForCallback(for: first) { _ in true }
        inbox.waitForCallback(for: second) { _ in true }

        inbox.stopWaiting(for: first)

        #expect(inbox.waitingFor == second, "a dead attempt unregistered the live sign-in")
        #expect(inbox.deliver(callback))
    }

    @Test("the attempt that owns the entry can end its own wait")
    func theOwnerStopsItsOwnWait() {
        let inbox = NativeLoginCallbackInbox()
        inbox.waitForCallback(for: first) { _ in true }

        inbox.stopWaiting(for: first)

        #expect(inbox.waitingFor == nil)
        #expect(!inbox.deliver(callback))
    }
}
