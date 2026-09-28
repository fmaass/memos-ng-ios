import Foundation

/// What the app's one-row dock shows (plan page 3929 decision 8).
///
/// Outside the Library the dock is the tab pill and nothing here changes it. Inside, it is either
/// the tabs — at the top, or after a tap on the active Library tab — or the Library's segment, the
/// Library icon beside Years | Months | All: entered the moment the page is scrolled past a small
/// threshold, kept until it is back at the top. No idle timer and no scroll-direction test.
///
/// Ported from the web's `frontend/src/lib/dockState.ts` (memos-ng 88453df). Every event carries
/// the tab it was observed on, which is what makes "outside the Library nothing changes" decidable
/// here rather than in a view body.
nonisolated public enum DockMode: String, Sendable, Equatable, CaseIterable {
    case tabs
    case segment

    public static let initial: DockMode = .tabs

    /// How far the Library scrolls before the segment replaces the tabs, in points — the web's 24
    /// CSS px taken over as it stands.
    public static let segmentThreshold: Double = 24

    /// The mode after `event`. An event that changes nothing answers the mode it was asked of.
    public func after(_ event: DockEvent) -> DockMode {
        switch event {
        case .leaveLibrary:
            return .tabs
        case .tapActive(let tab):
            guard tab == .library else { return self }
            return self == .tabs ? .segment : .tabs
        case .scroll(let y, let tab):
            guard tab == .library else { return self }
            // "At the top" is y <= 0, not y < threshold: rubber-banding reports negative offsets.
            if y <= 0 { return .tabs }
            if y > Self.segmentThreshold { return .segment }
            return self
        }
    }
}

/// What the dock hears.
nonisolated public enum DockEvent: Sendable, Equatable {
    /// The scroll view on screen moved. `y` is measured from the top of its content: 0 at rest,
    /// negative while rubber-banding.
    case scroll(y: Double, tab: MainTab)
    /// A tap on the tab that is already chosen — or, inside the Library's segment, on its icon.
    case tapActive(MainTab)
    /// The Library tab is no longer the one on screen.
    case leaveLibrary
}
