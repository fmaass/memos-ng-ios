import Foundation
import MemosCore
import SwiftUI

/// Chooses between the signed-in app and sign-in, and restores a stored credential at launch.
public struct RootView: View {
    @Environment(SessionStore.self) private var session
    // Optional for the same reason the outbox is on the timeline: a preview or a test host has no
    // settings store, and a missing environment value must not be a crash on the root view.
    @Environment(AppSettings.self) private var settings: AppSettings?

    public init() {}

    public var body: some View {
        Group {
            switch session.state {
            case .signedIn:
                MainTabView()
            case .unreachable(let message):
                UnreachableView(message: message)
            case .signedOut, .signingIn:
                SignInView()
            }
        }
        .tint(DesignTokens.accent)
        // Applied HERE, above the switch between the timeline and sign-in, because the choice has
        // to hold on every screen the app can be showing — the ones somebody signed out is looking
        // at included. What `nil` means is `AppSettings.colorScheme`'s decision, not this line's.
        .preferredColorScheme(AppSettings.colorScheme(for: settings?.appearance))
        // Both return trips of the native sign-in land here, and both are handed to the same
        // inbox: the sign-in waiting for a callback recognises its own, and every other URL the
        // app is ever opened with is refused there rather than acted on.
        //
        // Neither lane waits for the other, and nothing here prefers one: whichever arrives
        // first is the one that finishes the sign-in. In this deployment that is always the
        // custom scheme — the server is on internal-only DNS, so Apple's CDN can never fetch the
        // domain association and the universal link is permanently inert. The https lane is kept
        // for a future where a public association exists; it needs nothing here to begin working.
        .onOpenURL { url in
            NativeLoginCallbackInbox.shared.deliver(url)
        }
        // `onOpenURL` covers a universal link on most paths, but a browsing activity is how one
        // arrives when the system continues it into a launch, and a callback that reached the
        // app and was dropped on the doorstep is the failure this whole flow is about.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            NativeLoginCallbackInbox.shared.deliver(url)
        }
        .task {
            guard session.state.user == nil else { return }
            // The stored credential always gets the first word — the debug shortcut must not
            // overwrite or bypass a real session, even on a development device.
            await session.restore()
            #if DEBUG
            if case .signedOut = session.state,
                let credentials = DebugCredentials.fromEnvironment(
                    ProcessInfo.processInfo.environment
                )
            {
                await session.signIn(
                    serverAddress: credentials.serverAddress,
                    token: credentials.token
                )
            }
            #endif
        }
    }
}

/// A stored sign-in that could not be confirmed: the server was unreachable, not the token
/// wrong. Retry is the headline; walking away from the stored credential is the explicit,
/// consequence-labelled alternative — never the default.
struct UnreachableView: View {
    let message: String
    @Environment(SessionStore.self) private var session
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Can't reach your memos",
                systemImage: "wifi.exclamationmark",
                description: Text(message)
            )
            Button("Try again") { Task { await session.restore() } }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.accent)
            Button("Sign in differently") { confirmDiscard = true }
                .font(.footnote)
        }
        // An alert, for the same reason the sign-out confirmation is one: a confirmation dialog
        // renders here as a glass card that dims nothing and leaves its Cancel button out of both
        // the screen and the accessibility tree — on a destructive question whose whole purpose is
        // to be refusable. This is the only other one in the app; there are no more.
        .alert(
            "Discard the saved sign-in?",
            isPresented: $confirmDiscard
        ) {
            Button("Discard and sign in again", role: .destructive) {
                Task { await session.signOutWithoutRevoking() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The saved credential stays valid on the server until it expires or is"
                    + " revoked from the web app."
            )
        }
    }
}
