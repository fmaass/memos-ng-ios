import Foundation

/// What the bottom of the screen shows while the Library is the tab on screen (MEMNG-604,
/// MEMNG-679).
///
/// In `tabs` the system tab bar stands there, as on every other tab. In `scope` the tab bar steps
/// aside for the Library's own bottom toolbar: its icon at the leading edge, Years | Months | All
/// beside it, the way Photos draws a minimised bar. The system tab bar cannot be minimised on
/// demand (UIKit has no call for it, only the on-scroll behaviour), so the app swaps the two bars
/// instead, on the Library's own scroll: the tabs stand until the Library is scrolled past a small
/// threshold, then the scope toolbar takes their place, as the Timeline's bar minimises once it
/// scrolls. Only the Library icon gives the tabs back — no scroll does, the top of the page
/// included, because a pick in the scope control swaps the scroll view for one standing at its
/// top — and a press on the Library's item where the Library shows is the way into the scope on a
/// page too short to scroll.
nonisolated public enum DockMode: String, Sendable, Equatable, CaseIterable {
    case tabs
    case scope

    public static let initial: DockMode = .tabs

    /// How far the Library scrolls before the scope toolbar replaces the tabs, in points.
    public static let scopeThreshold: Double = 24

    /// The state after `event`. An event that changes nothing answers the state it was asked of.
    public func after(_ event: DockEvent) -> DockMode {
        switch event {
        case .pressedTab(let tab, let showing):
            // The Library pressed where it shows is the way into its scope; pressed from another
            // tab it is the way back to the Library, which comes back on the tabs.
            return tab == .library && showing == .library ? .scope : .tabs
        case .pressedLibraryIcon:
            return .tabs
        case .selected(let tab):
            // Leaving the Library by any route — a press elsewhere or a jump to a memo — gives
            // the tabs back, so coming back finds them.
            return tab == .library ? self : .tabs
        case .scrolled(let y, let showing):
            // A scroll counts on the Library alone: the one tab whose bars this decides.
            guard showing == .library, y > Self.scopeThreshold else { return self }
            return .scope
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
    /// One of the Library's scroll views moved while `showing` was the tab on screen. `y` is
    /// measured from the top of its content: 0 at rest, negative while rubber-banding.
    case scrolled(y: Double, showing: MainTab)
}

/// One reading of a Library scroll view, as the dock is fed it: how far it stands from the top
/// of its content, and the frame and insets it was measured in.
nonisolated public struct DockScrollReading: Sendable, Equatable {
    /// The content offset plus the top inset: 0 at rest, whatever bars stand over the top.
    public let y: Double
    public let width: Double
    public let height: Double
    public let insetTop: Double
    public let insetLeading: Double
    public let insetBottom: Double
    public let insetTrailing: Double

    public init(
        y: Double,
        width: Double,
        height: Double,
        insetTop: Double,
        insetLeading: Double,
        insetBottom: Double,
        insetTrailing: Double
    ) {
        self.y = y
        self.width = width
        self.height = height
        self.insetTop = insetTop
        self.insetLeading = insetLeading
        self.insetBottom = insetBottom
        self.insetTrailing = insetTrailing
    }

    /// Whether the frame or an inset differs from `other`'s: a bar came or went, a tab was shown
    /// again, the screen turned.
    public func reframed(from other: DockScrollReading) -> Bool {
        let frame = width != other.width || height != other.height
        let ends = insetTop != other.insetTop || insetBottom != other.insetBottom
        let sides = insetLeading != other.insetLeading || insetTrailing != other.insetTrailing
        return frame || ends || sides
    }
}

/// Tells a Library scroll the reader or the app made from the layout settling after the dock
/// swapped its bars (MEMNG-679).
///
/// When the dock changes what stands at the bottom — the scope toolbar swapped for the tab bar or
/// back, a tab shown again — the scroll view's frame and insets change, the lazy grid inside it
/// measures its rows anew, and the system moves the offset to keep what is on screen in place: in
/// a report of its own, AFTER the one that carried the new frame (the render test that presses
/// the icon at the foot of All saw a jump of several hundred points there, and the scope come
/// straight back). That is no scroll, and a rule that took it for one would swap the bars back.
///
/// So the judge asks for the cause, not the time alone. An offset that moves while the scroll
/// view is moving — a drag, its deceleration, an animated scroll — is the reader's or the
/// app's, and counts whenever it comes. An offset that moves while the scroll view is idle
/// counts too, except within `settling` of the dock's last swap, a window every reframe inside
/// it extends: that is the system keeping rows in place. A reframe with no swap opens no window,
/// so a jump the app makes — Months opening at a month, a new scroll view's first landing —
/// counts, with the reframe or after it. A kept offset is no scroll.
nonisolated public struct DockScrollFence: Sendable {
    /// How long after a swap, or a reframe that follows it, the layout is given to settle.
    public static let settling: Duration = .milliseconds(500)

    /// When the layout last changed inside a swap's window: the swap, or a reframe after it.
    private var settledFrom: ContinuousClock.Instant?

    public init() {}

    /// The offset the scroll moved to between `previous` and `now`, read at `instant`, or nil when
    /// the reading is no scroll. `swappedAt` is when the dock last swapped its bars, nil if it
    /// never did; `moving` is whether the scroll view was moving rather than idle.
    public mutating func scrolled(
        from previous: DockScrollReading,
        to now: DockScrollReading,
        at instant: ContinuousClock.Instant,
        swappedAt: ContinuousClock.Instant? = nil,
        moving: Bool = false
    ) -> Double? {
        if let swappedAt, settledFrom.map({ $0 < swappedAt }) ?? true {
            settledFrom = swappedAt
        }
        let settling = settledFrom.map { instant < $0.advanced(by: Self.settling) } ?? false
        if settling, now.reframed(from: previous) { settledFrom = instant }
        guard now.y != previous.y else { return nil }
        return settling && !moving ? nil : now.y
    }
}
