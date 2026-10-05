import Foundation

/// What the bottom of the screen shows while the Library is the tab on screen (MEMNG-604,
/// MEMNG-679, MEMNG-685).
///
/// In `tabs` the tabs' capsule stands there, as on every other tab. In `scope` it gives way to the
/// Library's scope row: its icon at the leading edge, Years | Months | All beside it, the way
/// Photos draws a minimised bar. The Library's own scroll swaps the two: the tabs stand until the
/// Library is scrolled past a small threshold, then the scope row takes their place, as the
/// Timeline's bar folds once it scrolls, and a scroll back to the top — a pull past it included —
/// gives the tabs back. Between
/// the two nothing changes. At the top it takes a scroll: a pick in the scope control swaps the
/// scroll view for one standing at its top, and a jump the app makes can land there, and neither
/// is one (`DockScrollKind`). The Library icon gives the tabs back wherever the Library stands,
/// and a press on the Library's item where the Library shows is the way into the scope on a page
/// too short to scroll.
///
/// In `folded` the main bar stands folded to the selected tab's icon (MEMNG-690), on the
/// Timeline's scroll down, given back by a scroll up, a return to the top or a press on the icon;
/// the Library never folds, its scroll is the scope's.
nonisolated public enum DockMode: String, Sendable, Equatable, CaseIterable {
    case tabs
    case scope
    case folded

    public static let initial: DockMode = .tabs

    /// How far the Library scrolls before the scope toolbar replaces the tabs, in points, and how
    /// far another tab scrolls down before its bar folds.
    public static let scopeThreshold: Double = 24

    /// Whether the main bar under `tab`'s root stands folded to its icon: in `folded`, on any tab
    /// but the Library.
    public func folds(on tab: MainTab) -> Bool {
        self == .folded && tab != .library
    }

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
            // the tabs back, so coming back finds them. A fold is the tab's it was made on.
            return tab == .library && self != .folded ? self : .tabs
        case .scrolled(let y, let showing, let kind):
            // A scroll counts on the Library alone: the one tab whose bars this decides.
            guard showing == .library else { return self }
            // Past the threshold the scope, whatever moved the Library there.
            if y > Self.scopeThreshold { return .scope }
            // At the top the tabs, on a scroll alone; between the two nothing changes.
            guard y <= 0, kind == .scroll else { return self }
            return .tabs
        case .scrolledTab(let tab, let folds, let showing):
            // A decision `DockFold` committed on the tab on screen, the Library's aside: its
            // scroll is the scope's.
            guard tab == showing, tab != .library, self != .scope else { return self }
            return folds ? .folded : .tabs
        }
    }
}

/// The reader's scroll of a tab's own scroll view, committed once per direction (MEMNG-690): what
/// folds and unfolds the leading bar, the way iOS minimises its own bar.
///
/// A decision per reading flipped the bar on every step against the drag — a finger that wavers
/// moves the offset back a point or two — and each flip restarted the bar's morph: the jerk build
/// 38 showed. So the travel is summed per run, a run being the moves made in one direction since
/// the last reversal or the start of a gesture: down `threshold` points commits the fold, up as far
/// commits the unfold, and the top of the content unfolds whatever the run. A move that is not the
/// reader's — the layout's or the app's, made while the scroll view is idle — neither counts nor
/// breaks a run, and a scroll that comes to rest keeps what it committed.
///
/// `moving` is the feed's `ScrollPhase.isScrolling`: every phase but `.idle`. `.tracking`,
/// `.interacting` and `.decelerating` are the reader's own. `.animating` counts too, on purpose:
/// the Timeline's animated scrolls — a jump's scroll to the new list's top, the status bar's
/// scroll to the top — end at the top, which unfolds whatever the run, so counting them can
/// only unfold early, never fold.
nonisolated public struct DockFold: Sendable, Equatable {
    /// How far one run travels before it commits, in points.
    public static let threshold: Double = DockMode.scopeThreshold

    /// The current run: down positive, 0 when none has begun.
    public private(set) var run: Double = 0

    public init() {}

    /// A gesture begins — the scroll view starts to move after resting: a new run, so a press on
    /// the icon between two gestures is not undone by the first point of the next.
    public mutating func began() { run = 0 }

    /// One reading: the scroll view stands `y` from the top of its content (0 at rest), moved `step`
    /// points since the last reading (down positive); `moving` is whether the reader's drag, its
    /// deceleration or an animated scroll moved it. Answers what the reading commits — true to
    /// fold, false to unfold — or nil when it commits nothing.
    public mutating func read(y: Double, step: Double, moving: Bool) -> Bool? {
        guard moving else { return nil }
        if y <= 0 {
            run = 0
            return false
        }
        guard step != 0 else { return nil }
        run = run == 0 || (run > 0) == (step > 0) ? run + step : step
        if run >= Self.threshold { return true }
        if run <= -Self.threshold { return false }
        return nil
    }
}

/// What holds the dock's claim on the bottom chrome, which says what stands in the bars' place
/// (MEMNG-684).
nonisolated public enum DockClaim: String, Sendable, Equatable, CaseIterable {
    /// The Library's select mode: its own toolbar stands where the bars stood, as in Photos.
    case select
    /// A pushed screen that stands for the whole app (`StackChrome`): nothing stands there.
    case takeover
}

/// The one bottom bar that stands under a tab's root (MEMNG-684): the tabs' capsule, the
/// Library's scope row, select mode's toolbar, or none of them.
///
/// Every bar is drawn from this one value and from nothing else, so no two of them can be asked
/// to stand at once: the tab bar stands only on `tabs`, the scope toolbar only on `scope`, select
/// mode's toolbar only on `select`.
nonisolated public enum DockBar: String, Sendable, Equatable, CaseIterable {
    case tabs
    case scope
    case select
    case none

    /// The bar under `tab`'s root while the dock is in `mode` and `claim` holds the chrome, nil
    /// when nothing does. A claim decides alone — a takeover leaves nothing, select mode its
    /// toolbar on the Library, whose mode alone it is — and leaves the mode as it was, so its end
    /// brings back the bar the mode names. With no claim the scope toolbar stands on the Library
    /// in `scope`, and the tab bar everywhere else.
    public static func standing(mode: DockMode, on tab: MainTab, claim: DockClaim?) -> DockBar {
        switch claim {
        case .takeover:
            return .none
        case .select:
            return tab == .library ? .select : .none
        case nil:
            // Folded is a shape of the tabs, not another bar (`DockMode.folds(on:)`).
            return tab == .library && mode == .scope ? .scope : .tabs
        }
    }
}

/// What the dock hears.
nonisolated public enum DockEvent: Sendable, Equatable {
    /// A press on `tab`'s item in the tab bar while `showing` was the tab on screen —
    /// the same tab when it is pressed again.
    case pressedTab(MainTab, showing: MainTab)
    /// A press on the Library icon in the Library's scope toolbar.
    case pressedLibraryIcon
    /// `tab` became the tab on screen, by a press or by the app.
    case selected(MainTab)
    /// One of the Library's scroll views moved while `showing` was the tab on screen. `y` is
    /// measured from the top of its content: 0 at rest, negative while rubber-banding. `by` is
    /// what moved it, as far as the dock can tell.
    case scrolled(y: Double, showing: MainTab, by: DockScrollKind)
    /// The reader's scroll of `tab`'s own scroll view — the Timeline's — committed a fold (`folds`)
    /// or an unfold (`DockFold`) while `showing` was on screen. Sent once per decision.
    case scrolledTab(MainTab, folds: Bool, showing: MainTab)
}

/// What moved a Library scroll view, of the moves the fence passes (`DockScrollFence`): whether
/// one that reaches the top gives the tabs back (MEMNG-685). Past the threshold every kind gives
/// the scope.
nonisolated public enum DockScrollKind: String, Sendable, Equatable, CaseIterable {
    /// A scroll: a move the fence judged one that nothing names as the app's — the reader's drag,
    /// its deceleration, an animated scroll, an idle move past the settling.
    case scroll
    /// A scope pick's landing: the offsets the layout settles as a pick swaps the Library's scroll
    /// view for another — the one it puts on screen standing at its top, and the one it takes
    /// away — until a scroll view next moves.
    case landing
    /// A jump the Library asked for (`askedToJump`): the app's own scroll to a day or a month.
    case jump

    /// What made a move. `asked`: the move is the jump the Library asked for; `moving`: the scroll
    /// view was moving (its scroll phase, the ask aside); `landing`: a scope pick was made and no
    /// scroll view has moved since. A move made while the scroll view moves is the reader's even
    /// in a pick's landing, so the landing never takes the reader's first scroll.
    public static func of(asked: Bool, moving: Bool, landing: Bool) -> DockScrollKind {
        if asked { return .jump }
        return landing && !moving ? .landing : .scroll
    }
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
/// back, a tab shown again, a claim taking the bars away or giving them back (MEMNG-684) — the
/// scroll view's frame and insets change, the lazy grid inside it
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
/// counts, with the reframe or after it, and gives the scope past the threshold. What it does at
/// the top is the dock's to say: it passes as the jump or the landing it is (`DockScrollKind`),
/// and only a scroll gives the tabs back there (MEMNG-685). A kept offset is no scroll.
///
/// A claim or a release (select mode's toolbar coming or going, MEMNG-684) holds the scroll view
/// longer than a swap: at the foot of a long grid the lazy stack measures its rows again on every
/// layout after the bars change, and the offset swings back and forth for a second or more, well
/// past `settling`. So once a scroll view lives through a claim or a release, its idle moves are
/// no scroll until it next moves: the reader's next drag, its deceleration or an animated scroll
/// counts at once and ends the hold, and so does a jump the Library asked for, which the caller
/// reports as moving. Lived through is the witness rule (review round 2): the fence had taken a
/// reading before the claim or release was made — its scroll view was there for it — and is
/// handed it within `settling` of it. A scroll view that came after it, the one a scope pick puts
/// on screen as Select ends, holds nothing however soon it is first heard, so its first landing
/// counts once the settling has passed, as any new scroll view's does.
nonisolated public struct DockScrollFence: Sendable {
    /// How long after a swap, or a reframe that follows it, the layout is given to settle.
    public static let settling: Duration = .milliseconds(500)

    /// When the layout last changed inside a swap's window: the swap, or a reframe after it.
    private var settledFrom: ContinuousClock.Instant?
    /// When this fence took its first reading: from then on its scroll view was there.
    private var firstRead: ContinuousClock.Instant?
    /// The last claim or release this fence was handed, and whether it holds idle moves now.
    private var heardHold: ContinuousClock.Instant?
    private var holding = false

    public init() {}

    /// The offset the scroll moved to between `previous` and `now`, read at `instant`, or nil when
    /// the reading is no scroll. `swappedAt` is when the dock last swapped its bars, nil if it
    /// never did; `heldAt` is when a claim was last made or ended, nil if none ever was;
    /// `moving` is whether the scroll view was moving rather than idle.
    public mutating func scrolled(
        from previous: DockScrollReading,
        to now: DockScrollReading,
        at instant: ContinuousClock.Instant,
        swappedAt: ContinuousClock.Instant? = nil,
        heldAt: ContinuousClock.Instant? = nil,
        moving: Bool = false
    ) -> Double? {
        if let swappedAt, settledFrom.map({ $0 < swappedAt }) ?? true {
            settledFrom = swappedAt
        }
        let firstRead = self.firstRead ?? instant
        self.firstRead = firstRead
        // The witness rule: a claim or release holds this fence only if the fence had read before
        // it was made and is handed it within the settling. One made before the first reading,
        // or first handed later, holds nothing.
        if let heldAt, heardHold.map({ $0 < heldAt }) ?? true {
            heardHold = heldAt
            holding = firstRead < heldAt && instant < heldAt.advanced(by: Self.settling)
        }
        if moving { holding = false }
        let settling = settledFrom.map { instant < $0.advanced(by: Self.settling) } ?? false
        if settling, now.reframed(from: previous) { settledFrom = instant }
        guard now.y != previous.y else { return nil }
        return (settling || holding) && !moving ? nil : now.y
    }
}
