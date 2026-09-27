import SwiftUI

/// The timeline's top bar, as a value rather than a body inside the screen.
///
/// Split out of `TimelineView` for one reason: which end of the bar a control sits at is a
/// DECISION, and a decision buried in a screen that cannot be constructed without a live session
/// is one no test can read back. `TimelineView` reads its
/// session and hands the answers down here as plain values, so this — the bar the app actually
/// ships — can be hosted on its own and its placements read out of a real `UINavigationBar`
/// (`TimelineToolbarTests`).
///
/// The arrangement, settled 2026-08-26:
///
/// - LEADING: a gear, which opens Settings. It was the account's own face until MEMNG-185, and
///   the face opened a menu of two items — a heading naming the account, and Settings. A menu
///   that exists to offer one destination is a tap nobody asked for, so the destination is now
///   the button: one press, straight to the screen. Who is signed in is still said, in the place
///   it was always said properly — the top of Settings, with the avatar beside it.
/// - TRAILING: New memo — the screen's primary action, the RIGHTMOST thing in the bar. A search
///   loupe sat immediately to its left from MEMNG-120 until MEMNG-513 retired the Timeline's text
///   search (pictures are found by tag in the Library now), so the bar holds two controls.
///   Nothing else is to be put there.
///
/// There is no menu here at all any more, and that is the end of a specific hazard rather than a
/// simplification: a menu opens with its first row directly under the anchor that opened it, and
/// when that row was a destructive "Sign out" a second tap on the anchor — the reflex when a tap
/// seems not to have registered — revoked a live credential (MEMNG-119). The heading row was put
/// there to stand in the way. Nothing in this corner can take anything away now: the gear
/// navigates, and signing out is the last row on the Settings screen, behind a confirmation
/// (`SignOutFlow`).
struct TimelineToolbar: ToolbarContent {
    /// Bumped once per memo made, so the pencil bounces. A plain count rather than the feedback
    /// trigger itself: `symbolEffect` wants a value it can compare, and nothing else here needs
    /// the rest of the trigger.
    let composed: Int
    let openSettings: () -> Void
    let newMemo: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            SettingsToolbarButton(openSettings: openSettings)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: newMemo) {
                Image(systemName: "square.and.pencil")
                    .symbolEffect(.bounce, value: composed)
            }
            .accessibilityLabel("New memo")
        }
    }
}

/// The way into Settings, as a view of its own.
///
/// A view rather than a `Button` written inline in the toolbar body, and for a reason a placement
/// test cannot cover: SwiftUI wraps a bar item in a host of its own, and that host carries the
/// accessibility label while refusing to be activated — so a press driven through the hosted
/// navigation bar does nothing whether the button is wired up or not, which is a test that passes
/// and proves nothing. Hosted on its own it is an ordinary button, and pressing it either runs the
/// navigation or does not (`TimelineToolbarTests`).
struct SettingsToolbarButton: View {
    let openSettings: () -> Void

    var body: some View {
        Button(action: openSettings) {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }
}
