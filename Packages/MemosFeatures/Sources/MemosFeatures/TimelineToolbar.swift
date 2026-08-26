import SwiftUI

/// The timeline's top bar, as a value rather than a body inside the screen.
///
/// Split out of `TimelineView` for the reason `AccountMenuRows` was split out of the menu: which
/// end of the bar a control sits at is a DECISION, and a decision buried in a screen that cannot
/// be constructed without a live session is one no test can read back. `TimelineView` reads its
/// session and hands the answers down here as plain values, so this — the bar the app actually
/// ships — can be hosted on its own and its placements read out of a real `UINavigationBar`
/// (`TimelineToolbarTests`).
///
/// The arrangement, settled 2026-08-26:
///
/// - LEADING: the account's own face, the anchor of the menu holding Settings and Sign out. It
///   sat beside New memo until now, and a face pressed against the screen's primary button read
///   as a second button rather than as who you are. The corner opposite the action is where the
///   web app and every other app on the household's phones keep the account, so that is where it
///   goes.
/// - TRAILING: the search loupe and then New memo — the screen's primary action, still the
///   RIGHTMOST thing in the bar. The loupe took the slot reserved for it immediately to New
///   memo's left (MEMNG-120): it arrived BESIDE New memo rather than displacing it, and the bar
///   holds three controls now. Nothing else is to be put there.
///
/// The loupe is a TARGET, not a control. Everything a search is made of — typing, clearing,
/// dismissing — happens in the sheet it raises, where a thumb can reach it; the corner costs one
/// tap and nothing else (`SearchSheet`).
///
/// The menu itself is driven by `AccountMenu.rows`, which is where the ORDER lives — because the
/// order carries a safety property. A menu opens with its first row directly under the anchor
/// that opened it, and when that row was the destructive one a second tap on the anchor revoked a
/// live credential (MEMNG-119). The heading occupies that position, the destructive row is last,
/// and the tap itself only ever asks (`SignOutFlow`) — none of which the move to the other corner
/// touches. The rows are built by walking that list rather than written out here, so the tests
/// that hold the order are holding THIS menu, and `AccountMenuRows` is the same view the
/// screenshot render draws.
struct TimelineToolbar: ToolbarContent {
    /// The account's picture, already decoded by the screen; `nil` draws the monogram instead.
    let avatar: Image?
    /// Who is signed in — the menu's heading and, without a picture, the monogram. `nil` is an
    /// account with no name, which both of those still have an answer for.
    let name: String?
    /// Bumped once per memo made, so the pencil bounces. A plain count rather than the feedback
    /// trigger itself: `symbolEffect` wants a value it can compare, and nothing else here needs
    /// the rest of the trigger.
    let composed: Int
    let openSettings: () -> Void
    let signOut: () -> Void
    let search: () -> Void
    let newMemo: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                AccountMenuRows(
                    rows: AccountMenu.rows(name: name),
                    openSettings: openSettings,
                    signOut: signOut
                )
            } label: {
                AccountAvatarView(image: avatar, name: name ?? "")
            }
            .accessibilityLabel("Account")
        }
        // Declared BEFORE New memo, which is what puts it to New memo's left: items with one
        // placement are laid out in the order they are written, leading to trailing. The
        // arrangement is measured out of a real bar rather than trusted to that
        // (`TimelineToolbarTests`).
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: search) {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search")
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
