import Foundation

/// What the bottom of the screen shows while the Library is the tab on screen (MEMNG-604).
///
/// Two states, and only taps move between them. In `tabs` the system tab bar stands there, as on
/// every other tab. In `scope` the tab bar steps aside for the Library's own bottom toolbar: its
/// icon at the leading edge, Years | Months | All beside it, the way Photos draws a minimised bar.
/// The system tab bar cannot be minimised on demand (UIKit has no call for it, only the
/// on-scroll behaviour), so the app swaps the two bars instead, and a scroll changes nothing.
nonisolated public enum DockMode: String, Sendable, Equatable, CaseIterable {
    case tabs
    case scope

    public static let initial: DockMode = .tabs

    /// The state after `event`. An event that changes nothing answers the state it was asked of.
    public func after(_ event: DockEvent) -> DockMode {
        switch event {
        case .pressedTab(let tab, _):
            // Every press on the Library, from another tab or on the Library itself. Narrowing
            // it to a press on the tab already showing is this line alone:
            // `tab == .library && showing == .library`.
            return tab == .library ? .scope : .tabs
        case .pressedLibraryIcon:
            return .tabs
        case .selected(let tab):
            // Leaving the Library by any route — a press elsewhere or a jump to a memo — gives
            // the tabs back, so coming back finds them.
            return tab == .library ? self : .tabs
        }
    }
}

/// What the dock hears.
nonisolated public enum DockEvent: Sendable, Equatable {
    /// A press on `tab`'s item in the system tab bar while `showing` was the tab on screen —
    /// the same tab when it is pressed again.
    case pressedTab(MainTab, showing: MainTab)
    /// A press on the Library icon in the Library's scope toolbar.
    case pressedLibraryIcon
    /// `tab` became the tab on screen, by a press or by the app.
    case selected(MainTab)
}
