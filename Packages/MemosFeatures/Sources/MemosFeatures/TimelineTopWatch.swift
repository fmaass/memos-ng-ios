import CoreGraphics

/// When a list that has something above it should reach for it.
///
/// The obvious trigger — the top row appearing — is the wrong one, and wrong in a way that is hard
/// to see from a screenshot. A list rebuilt by a jump renders its top rows immediately, so "the
/// top row appeared" fires the instant the jump lands and pages the very memos the reader jumped
/// away from straight back on top of the day they asked for. It fires again after every prepend,
/// because the block that was just put above the reader is rendered too, and the list walks itself
/// back to today without anybody scrolling.
///
/// So the trigger is a scroll ARRIVAL, not a row appearance: the list has to have been away from
/// the top and come back. That is one bit of state, and keeping it here rather than in the view
/// is what lets the sequence be asserted — a jump, a settle, a scroll down, a scroll up — instead
/// of eyeballed on a device (MEMNG-179).
struct TimelineTopWatch: Equatable {
    /// Whether the list has been somewhere other than the top since the last fetch or reset.
    private(set) var scrolledAway = false

    init() {}

    /// Forgets that the list was ever away from the top.
    ///
    /// Called when a jump has finished animating. The jump scrolls the list to the top from
    /// wherever the previous list stood, and the frames in between are genuinely "not at the
    /// top" — without this, arriving at the anchored day would itself count as a reader scrolling
    /// back up to it.
    mutating func settled() {
        scrolledAway = false
    }

    /// One scroll reading. True exactly when the list has just ARRIVED at the top from below,
    /// which is the moment the page above is worth asking for.
    mutating func arrivedAtTop(_ atTop: Bool) -> Bool {
        guard atTop else {
            scrolledAway = true
            return false
        }
        guard scrolledAway else { return false }
        scrolledAway = false
        return true
    }

    /// Whether a scroll geometry is at the top of its content.
    ///
    /// `contentOffset` is measured from the content's own origin and the inset sits above it, so
    /// a list at rest at the top reads `contentOffset.y == -contentInsets.top`; the sum is what
    /// is actually zero there. The slack makes it fire a little before the very top, so the page
    /// above is on its way while the last rows are still going past rather than after the scroll
    /// has already stopped dead.
    static func isAtTop(contentOffsetY: CGFloat, topInset: CGFloat, slack: CGFloat = 40) -> Bool {
        contentOffsetY + topInset <= slack
    }
}
