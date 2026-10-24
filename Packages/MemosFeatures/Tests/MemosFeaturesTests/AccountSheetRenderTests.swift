import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// A server that knows who is signed in, the account's settings and this phone's token, and that
/// FAILS every revoke — so a sign-out started here can be explained, retried and outlived, and
/// never ends the session under the test. Revokes can be held, to be answered after the sheet
/// has gone. Every other read fails plainly.
private nonisolated final class AccountSheetServer: ClientTransport, @unchecked Sendable {
    private let displayName: String
    private let defaultVisibility: String
    private let refusesSettings: Bool
    private let lock = NSLock()
    private var logouts = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(displayName: String, defaultVisibility: String = "PUBLIC", refusesSettings: Bool = false) {
        self.displayName = displayName
        self.defaultVisibility = defaultVisibility
        self.refusesSettings = refusesSettings
    }

    /// The revokes that reached the wire, counted as they ARRIVE.
    var revokes: Int { lock.withLock { logouts } }

    func holdRevokes() { lock.withLock { holding = true } }

    func releaseRevokes() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            defer { held = [] }
            return held
        }
        for continuation in waiting { continuation.resume() }
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let payload: String
        switch operationID {
        case "whoami_api_auth_user_get":
            payload = """
                {"subject":"sub-7f3a","display_name":"\(displayName)",\
                "email":"fabian@example.invalid","role":"user","auth_kind":"oidc"}
                """
        case "get_settings_api_settings_get":
            payload = """
                {"default_visibility":"\(defaultVisibility)","theme":"dark","avatar":null}
                """
        case "update_settings_api_settings_patch" where refusesSettings:
            return (HTTPResponse(status: .internalServerError), nil)
        case "native_token_api_auth_native_token_get":
            payload = """
                {"name":"Kitchen phone","created_at":"2026-08-01T09:00:00Z",\
                "last_used":"2026-08-27T09:00:00Z","expires_at":"2027-08-01T09:00:00Z"}
                """
        case "native_logout_api_auth_native_logout_post":
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let go = lock.withLock { () -> Bool in
                    logouts += 1
                    if !holding { return true }
                    held.append(continuation)
                    return false
                }
                if go { continuation.resume() }
            }
            return (HTTPResponse(status: .internalServerError), nil)
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(payload))
    }
}

/// The keychain, in memory.
private final class AccountSheetCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func set(_ value: String, for account: String) async throws {
        lock.withLock { values[account] = value }
    }

    func string(for account: String) async throws -> String? {
        lock.withLock { values[account] }
    }

    func remove(_ account: String) async throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

/// A real `SessionStore`, signed in through the real generated client over `server`.
@MainActor
private func signedIn(over server: AccountSheetServer) async -> SessionStore {
    let session = SessionStore(
        credentials: AccountSheetCredentials(),
        makeClient: { configuration, credential in
            APIClientFactory.make(
                configuration: configuration, credential: credential, transport: server)
        },
        sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
        noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
        // Its own clock, so a sign-in here rotates nothing another suite is counting on.
        identity: MediaIdentity()
    )
    await session.enteredForeground()
    await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_accountsheet")
    return session
}

/// Whether the account sheet is up, owned by the test so it can put the sheet away.
@MainActor
@Observable
private final class AccountPresence {
    var open = true
}

/// The level the sheet is presented from, built from the modifier the Timeline uses
/// (`accountSheet`) and nothing else: a navigation stack, and the sheet over it.
private struct UnderTheSheet: View {
    @Bindable var presence: AccountPresence
    let signOut: SignOutConversation

    var body: some View {
        NavigationStack { Text("The timeline under the sheet") }
            .accountSheet(isPresented: $presence.open, signOut: signOut, avatar: nil)
    }
}

@MainActor
private enum SheetProbe {
    /// The alert presented over `host`, if one is, with how many presentations deep it sits: 1
    /// when the level under the sheet asked, 2 when the sheet did.
    static func alert(over host: UIViewController) -> (title: String?, depth: Int)? {
        var next = host.presentedViewController
        var depth = 1
        while let controller = next {
            if let alert = controller as? UIAlertController { return (alert.title, depth) }
            next = controller.presentedViewController
            depth += 1
        }
        return nil
    }

    /// The title of the alert presented over `host` once it is AT REST — fully presented, no
    /// transition running, in a window — or nil while there is none or it is still moving.
    ///
    /// What a press needs before it is pressed: a person cannot tap an alert that is still
    /// arriving, and `TripProbe.pressAlert` dismisses the alert it presses. The lost retry this
    /// wait was written for turned out to be two other things — the alert binding's own setter
    /// firing a cancel late, after the next question was asked (those setters are inert now,
    /// `SignOutConversation.askingPresented`), and a press that ran its handler before the alert
    /// had gone, so the next question collided with it (`pressAlert` keeps UIKit's order) — but a
    /// press on an alert still in transition is not a tap a person could make, so the wait stays.
    static func alertAtRest(over host: UIViewController) -> String? {
        var next = host.presentedViewController
        while let controller = next {
            if let alert = controller as? UIAlertController {
                let moving =
                    alert.isBeingPresented || alert.isBeingDismissed
                    || alert.transitionCoordinator != nil || alert.view.window == nil
                return moving ? nil : alert.title
            }
            next = controller.presentedViewController
        }
        return nil
    }

    /// How many presentations are stacked over `host`.
    static func presentations(over host: UIViewController) -> Int {
        var next = host.presentedViewController
        var count = 0
        while let controller = next {
            count += 1
            next = controller.presentedViewController
        }
        return count
    }

    /// The sheet is up and its Sign out row is on the screen.
    static func sheetIsUp(_ screen: PressProbe.Screen) async -> Bool {
        await TripProbe.settled(seconds: 5) {
            presentations(over: screen.host) == 1 && screen.element(labelled: "Sign out") != nil
        }
    }
}

/// The account sheet as it is drawn: the real `AccountSheet` over a real `SessionStore` signed in
/// through the real generated client. It replaces the Settings screen's account and defaults
/// cards (chrome trim, 2026-10-10), so what that screen was held to, this is.
///
/// The avatar's initials are not in the labels these cases read — the avatar is hidden from the
/// accessibility tree — so they are read through a witness by `AccountAvatarNameTests` below.
@MainActor
@Suite("The account sheet")
struct AccountSheetRenderTests {
    private let tall = CGSize(width: 393, height: 1400)

    /// For an account whose display name came back blank, the row names it by its address — not
    /// a bare "Signed in", which is what it read while `User.name` handed over the blank.
    @Test(
        "an account with a blank display name is headed by its address",
        arguments: ["", "  "]
    )
    func aBlankDisplayNameIsHeadedByTheAddress(blank: String) async {
        let session = await signedIn(over: AccountSheetServer(displayName: blank))
        #expect(session.state.user?.displayName == blank, "precondition: signed in, name blank")

        let labels = ScreenProbe.labels(
            of: AccountSheet(signOut: SignOutConversation(), avatar: nil).environment(session)
        )

        // The control: the row is on the screen at all, so a miss below is about its words.
        #expect(labels.contains { $0.contains("Signed in") }, "the account row was not drawn")
        #expect(
            labels.contains { $0.contains("Signed in as fabian@example.invalid") },
            "display name \(blank.debugDescription) did not head the row with the address"
        )
    }

    /// Everything the Settings screen did that the Settings app cannot, on the one sheet: the
    /// token's two actions, Manage tokens, the visibility choice with the notice an account set
    /// to PROTECTED on the web is owed, the pointer to the Settings app, and Sign out LAST.
    @Test("the sheet holds the token, Manage tokens, the default, and Sign out last")
    func theSheetHoldsWhatTheScreenDid() async throws {
        let session = await signedIn(
            over: AccountSheetServer(displayName: "Fabian", defaultVisibility: "PROTECTED"))
        await session.loadSettings()
        await session.loadDeviceToken()
        #expect(session.defaultVisibility == .protected, "precondition: PROTECTED was read")

        let labels = ScreenProbe.labels(
            of: AccountSheet(signOut: SignOutConversation(), avatar: nil).environment(session),
            size: tall
        )

        let notice = try #require(DefaultVisibilityChoice.notice(for: .protected))
        for expected in [
            DeviceTokenPresentation.renameLabel, DeviceTokenPresentation.renewLabel,
            ManageTokensPresentation.rowLabel, notice, AccountSheet.footer, "Sign out",
        ] {
            #expect(labels.contains { $0.contains(expected) }, "no \(expected): \(labels)")
        }
        let signOut = try #require(labels.lastIndex { $0.contains("Sign out") })
        let controls = labels.indices.filter { index in
            [DeviceTokenPresentation.renameLabel, ManageTokensPresentation.rowLabel, notice]
                .contains { labels[index].contains($0) }
        }
        #expect(controls.count >= 3, "a control above Sign out is missing: \(labels)")
        #expect(controls.allSatisfy { $0 < signOut }, "Sign out is not last: \(labels)")
    }

    /// The sheet's own answer to a default the server did not take: the row stays where it was
    /// and the sheet says so, rather than the tap vanishing.
    @Test("a default the server refuses is said on the sheet, and the default is unchanged")
    func aRefusedDefaultIsSaid() async {
        let session = await signedIn(
            over: AccountSheetServer(displayName: "Fabian", refusesSettings: true))
        await session.loadSettings()
        #expect(session.defaultVisibility == .public, "precondition: PUBLIC was read")

        let said = await PressProbe.withScreen(
            AccountSheet(signOut: SignOutConversation(), avatar: nil).environment(session),
            height: tall.height
        ) { screen in
            #expect(!screen.says(AccountSheet.refusedVisibility), "the notice was up before a tap")
            #expect(
                screen.pressSegment(MemoVisibility.private.label),
                "the Private segment took no press: \(screen.segmentTitles)"
            )
            return await TripProbe.settled(seconds: 5) {
                screen.says(AccountSheet.refusedVisibility)
            }
        }

        #expect(said, "a refused default left the sheet silent")
        #expect(session.defaultVisibility == .public)
    }

    @Test("pressing Sign out on the sheet asks the shared conversation, and revokes nothing")
    func pressingSignOutAsks() async {
        let server = AccountSheetServer(displayName: "Fabian")
        let session = await signedIn(over: server)
        let conversation = SignOutConversation()

        let pressed = PressProbe.withElement(
            labelled: "Sign out",
            in: AccountSheet(signOut: conversation, avatar: nil).environment(session),
            height: tall.height
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the sheet's Sign out did not accept an activation")
        #expect(conversation.stage == .asking)
        #expect(server.revokes == 0)
        #expect(session.state.user != nil, "asking signed the session out")
    }

    /// Manage tokens is a sheet of its own, opened FROM this sheet: a presentation over a
    /// presentation, which is the case that silently fails when it hangs from the wrong view.
    @Test("Manage tokens opens over the account sheet")
    func manageTokensOpensOverTheSheet() async {
        let session = await signedIn(over: AccountSheetServer(displayName: "Fabian"))
        let presence = AccountPresence()

        let opened = await PressProbe.withScreen(
            UnderTheSheet(presence: presence, signOut: SignOutConversation())
                .environment(session),
            height: 852
        ) { screen in
            #expect(await SheetProbe.sheetIsUp(screen), "the account sheet never came up")
            #expect(screen.press(ManageTokensPresentation.rowLabel), "Manage tokens took no press")
            return await TripProbe.settled(seconds: 5) {
                SheetProbe.presentations(over: screen.host) == 2
                    && screen.element(labelled: ManageTokensPresentation.signOnLabel) != nil
            }
        }

        #expect(opened, "Manage tokens did not open over the account sheet")
    }

    /// The version line at the foot of the sheet (MEMNG-497): it reads this build as the Settings
    /// app's Version row does, and ONE press on it pushes What's new in the sheet's own stack, the
    /// running build's section heading the screen. Pressed through the element the probe finds,
    /// not by building the destination: the link's wiring is what is under test.
    @Test("the version line at the foot opens What's new, the running build's section first")
    func theVersionLineOpensWhatsNew() async {
        let session = await signedIn(over: AccountSheetServer(displayName: "Fabian"))
        let running = AboutInfo.versionLine(from: .main)
        #expect(running != "Unknown", "precondition: the host app declares its version")
        let versions = Set(ReleaseNotes.bundled.map(\.version))
        #expect(versions.contains(running), "precondition: the notes name \(running)")

        let shown = await PressProbe.withScreen(
            AccountSheet(signOut: SignOutConversation(), avatar: nil).environment(session),
            height: 2400
        ) { screen -> [String] in
            #expect(screen.element(labelled: running) != nil, "the foot does not read \(running)")
            #expect(screen.press(running), "the version line took no press")
            let pushed = await TripProbe.settled(seconds: 5) {
                screen.says(WhatsNewView.title) && screen.element(labelled: running) == nil
            }
            #expect(pushed, "What's new was not pushed over the sheet's own screen")
            return WhatsNewProbe.labels(in: screen.window, among: versions)
        }

        #expect(shown.first == running, "the first section is not the running build's: \(shown)")
        #expect(shown.count >= 2, "the earlier builds were not drawn after it: \(shown)")
    }

    /// The destination alone, over notes whose running build sits in the MIDDLE of the file: the
    /// order on the screen is the running build, then the rest as written, and each body is drawn.
    @Test("What's new draws the running build first and the rest in file order")
    func whatsNewDrawsTheRunningBuildFirst() async {
        let notes = ReleaseNotes.sections(
            markdown: "## 3.0 (3)\n- Three.\n## 2.0 (2)\n- Two.\n## 1.0 (1)\n- One.\n")
        let versions: Set = ["3.0 (3)", "2.0 (2)", "1.0 (1)"]

        let (shown, bodies) = await PressProbe.withScreen(
            NavigationStack { WhatsNewView(running: "2.0 (2)", notes: notes) },
            height: tall.height
        ) { screen -> ([String], Bool) in
            let bodies = await TripProbe.settled(seconds: 5) {
                ["Three.", "Two.", "One."].allSatisfy { screen.says($0) }
            }
            return (WhatsNewProbe.labels(in: screen.window, among: versions), bodies)
        }

        #expect(shown == ["2.0 (2)", "3.0 (3)", "1.0 (1)"], "drawn in this order: \(shown)")
        #expect(bodies, "a section's Markdown was not drawn")
    }
}

/// The section headings on a window, top to bottom, each once. Ordered by where each one is drawn
/// rather than by the view tree: a list's cells sit in its hierarchy in whatever order it reused
/// them, and a hosting view can expose the same text both as itself and as an element.
@MainActor
private enum WhatsNewProbe {
    static func labels(in window: UIWindow, among wanted: Set<String>) -> [String] {
        var found: [(label: String, top: CGFloat)] = []
        collect(window, wanted: wanted, into: &found)
        var seen = Set<String>()
        return found.sorted { $0.top < $1.top }.map(\.label).filter { seen.insert($0).inserted }
    }

    private static func collect(
        _ node: Any, wanted: Set<String>, into found: inout [(label: String, top: CGFloat)]
    ) {
        if let element = node as? NSObject {
            if let label = element.accessibilityLabel, wanted.contains(label) {
                found.append((label, element.accessibilityFrame.minY))
            }
            for child in element.accessibilityElements ?? [] {
                collect(child, wanted: wanted, into: &found)
            }
        }
        if let view = node as? UIView {
            for subview in view.subviews { collect(subview, wanted: wanted, into: &found) }
        }
    }
}

/// Signing out from the account sheet, end to end over the modifier the Timeline uses: the
/// question asked ON the sheet while it is up, its answers, a revoke that fails while the sheet
/// is up, and one that fails after the sheet has gone. One `SignOutConversation` throughout,
/// owned here as the Timeline owns its own.
@MainActor
@Suite("Signing out from the account sheet")
struct AccountSheetSignOutTests {
    private func withSheet<T>(
        _ server: AccountSheetServer,
        _ body: (PressProbe.Screen, SignOutConversation, AccountPresence, SessionStore) async -> T
    ) async -> T {
        let session = await signedIn(over: server)
        let conversation = SignOutConversation()
        let presence = AccountPresence()
        return await PressProbe.withScreen(
            UnderTheSheet(presence: presence, signOut: conversation).environment(session),
            height: 852
        ) { screen in
            await body(screen, conversation, presence, session)
        }
    }

    @Test("the question is asked on the sheet, with both answers")
    func theQuestionIsAskedOnTheSheet() async {
        let server = AccountSheetServer(displayName: "Fabian")
        await withSheet(server) { screen, conversation, _, _ in
            #expect(await SheetProbe.sheetIsUp(screen), "the account sheet never came up")
            #expect(screen.press("Sign out"), "the sheet's Sign out took no press")

            let asked = await TripProbe.settled(seconds: 5) {
                SheetProbe.alert(over: screen.host)?.title == "Sign out?"
            }
            #expect(asked, "no question: \(TripProbe.presentation(screen))")
            #expect(SheetProbe.alert(over: screen.host)?.depth == 2, "not asked on the sheet")
            #expect(TripProbe.dialogActions(in: screen.host) == ["Sign out", "Cancel"])
            #expect(conversation.stage == .asking)
        }
        #expect(server.revokes == 0, "asking revoked")
    }

    @Test("Cancel puts the question away, revokes nothing, and leaves the sheet up")
    func cancelRevokesNothing() async {
        let server = AccountSheetServer(displayName: "Fabian")
        await withSheet(server) { screen, conversation, _, session in
            #expect(await SheetProbe.sheetIsUp(screen), "the account sheet never came up")
            #expect(screen.press("Sign out"))
            _ = await TripProbe.settled(seconds: 5) { SheetProbe.alert(over: screen.host) != nil }

            #expect(TripProbe.pressAlert("Cancel", in: screen.host), "no Cancel to press")
            let gone = await TripProbe.settled(seconds: 5) {
                SheetProbe.alert(over: screen.host) == nil
            }

            #expect(gone, "the question stayed up: \(TripProbe.presentation(screen))")
            #expect(conversation.stage == .idle)
            #expect(SheetProbe.presentations(over: screen.host) == 1, "the sheet went with it")
            #expect(session.state.user != nil)
        }
        #expect(server.revokes == 0, "Cancel revoked")
    }

    /// The event arrives WHILE the sheet is up — a revoke that failed — and the sheet is what
    /// explains it, not the level underneath it, whose alert could not appear under a sheet.
    /// Then the retry: one more revoke, never two.
    @Test("a revoke that fails while the sheet is up is explained on the sheet, and retried")
    func aFailedRevokeIsExplainedOnTheSheet() async {
        let server = AccountSheetServer(displayName: "Fabian")
        await withSheet(server) { screen, conversation, _, session in
            #expect(await SheetProbe.sheetIsUp(screen), "the account sheet never came up")
            #expect(screen.press("Sign out"))
            _ = await TripProbe.settled(seconds: 5) {
                SheetProbe.alertAtRest(over: screen.host) == "Sign out?"
            }
            #expect(TripProbe.pressAlert("Sign out", in: screen.host), "no Sign out to confirm")

            // At rest, not merely in the chain: a Try again pressed while the explanation is still
            // arriving can be answered as a cancel first, and is then a retry nobody sent.
            let explained = await TripProbe.settled(seconds: 5) {
                SheetProbe.alertAtRest(over: screen.host) == "Could not sign out"
            }
            #expect(explained, "the failure was not explained: \(TripProbe.presentation(screen))")
            #expect(SheetProbe.alert(over: screen.host)?.depth == 2, "not explained on the sheet")
            #expect(server.revokes == 1)
            #expect(session.state.user != nil, "a failed revoke ended the session")
            #expect(
                conversation.explanation != nil,
                "the explanation was put away before Try again: \(conversation.stage)"
            )

            #expect(TripProbe.pressAlert("Try again", in: screen.host), "no Try again to press")
            let retried = await TripProbe.settled(seconds: 5) { server.revokes == 2 }
            #expect(retried, "Try again sent \(server.revokes - 1) revokes")
            _ = await TripProbe.settled(seconds: 5) {
                if case .explaining = conversation.stage { return true }
                return false
            }
        }
        #expect(server.revokes == 2, "one retry is one more revoke")
    }

    /// The event arrives AFTER the sheet has gone — a revoke still on the wire when it was put
    /// away — and the level the sheet leaves behind is what explains it.
    ///
    /// The yes is sent to the conversation directly rather than pressed on the sheet's alert, so
    /// this holds the level UNDER the sheet alone: what the sheet's own alerts do is held above.
    @Test("a revoke that fails after the sheet is dismissed is explained under it")
    func aRevokeOutlivingTheSheetIsExplainedUnderIt() async {
        let server = AccountSheetServer(displayName: "Fabian")
        server.holdRevokes()
        await withSheet(server) { screen, conversation, presence, session in
            #expect(await SheetProbe.sheetIsUp(screen), "the account sheet never came up")
            #expect(screen.press("Sign out"), "the sheet's Sign out took no press")
            conversation.send(.confirmed, to: session)
            #expect(await TripProbe.settled(seconds: 5) { server.revokes == 1 }, "no revoke sent")
            #expect(conversation.stage == .revoking)
            _ = await TripProbe.settled(seconds: 5) { SheetProbe.alert(over: screen.host) == nil }

            presence.open = false
            let dismissed = await TripProbe.settled(seconds: 5) {
                SheetProbe.presentations(over: screen.host) == 0
            }
            #expect(dismissed, "the sheet stayed up: \(TripProbe.presentation(screen))")

            server.releaseRevokes()
            let explained = await TripProbe.settled(seconds: 5) {
                SheetProbe.alert(over: screen.host)?.title == "Could not sign out"
            }
            #expect(explained, "nothing explained it: \(TripProbe.presentation(screen))")
            #expect(SheetProbe.alert(over: screen.host)?.depth == 1, "not explained under it")
        }
        #expect(server.revokes == 1)
    }
}

/// The account's face, drawn from the account's name at both places the app draws it: the top of
/// the account sheet and the Timeline's leading toolbar button (MEMNG-697).
///
/// The face is hidden from VoiceOver, so no label a probe reads carries its initials, and a site
/// that stopped handing `User.name` down would draw "?" under every other test here. Each case
/// hands the screen an `AccountAvatarWitness` and reads back the monogram it drew. The name is one
/// whose initials are neither "?" nor the address's "F", so a site that dropped it, or fell back
/// to anything else, draws something else.
@MainActor
@Suite("The account's face")
struct AccountAvatarNameTests {
    private let name = "Ada Lovelace"

    /// Puts `view` on a screen with `witness` in its environment and turns the run loop until a
    /// monogram has been drawn — a toolbar item is installed a turn or more after the first
    /// layout — or two seconds have passed, then once more so a later name is drawn too.
    private func monograms(
        drawnBy view: some View, into witness: AccountAvatarWitness
    ) async -> [String] {
        let host = UIHostingController(rootView: view.environment(\.accountAvatarWitness, witness))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for _ in 0..<80 where witness.drawn.isEmpty {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        return witness.drawn
    }

    /// `AccountSheet` hands the avatar at its head the signed-in account's name.
    @Test("the account sheet draws the account's initials")
    func theSheetDrawsTheAccountsInitials() async {
        let session = await signedIn(over: AccountSheetServer(displayName: name))
        #expect(session.state.user?.name == name, "precondition: signed in under the name")

        let drawn = await monograms(
            drawnBy: AccountSheet(signOut: SignOutConversation(), avatar: nil).environment(session),
            into: AccountAvatarWitness()
        )

        // The control: the sheet drew a monogram at all, so a miss below is about whose it is.
        #expect(!drawn.isEmpty, "the account sheet drew no monogram")
        #expect(drawn.last == "AL", "the sheet's avatar drew \(drawn), not the account's initials")
    }

    /// The whole road to the toolbar's face: `TimelineView` reads the name off the session,
    /// `TimelineToolbar` hands it to `AccountToolbarButton`, and the button to the avatar. Hosted
    /// as the screen rather than the button alone, so a link dropped anywhere on that road fails.
    @Test("the Timeline's account button draws the account's initials")
    func theTimelineButtonDrawsTheAccountsInitials() async {
        let session = await signedIn(over: AccountSheetServer(displayName: name))
        #expect(session.state.user?.name == name, "precondition: signed in under the name")

        let drawn = await monograms(
            drawnBy: TimelineView().environment(session), into: AccountAvatarWitness())

        #expect(!drawn.isEmpty, "the Timeline's toolbar drew no monogram")
        #expect(drawn.last == "AL", "the toolbar's avatar drew \(drawn), not the initials")
    }
}
