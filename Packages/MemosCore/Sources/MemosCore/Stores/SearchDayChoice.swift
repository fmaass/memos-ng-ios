import Foundation

/// A day chosen in the search sheet, and what choosing it that way does to the sheet.
///
/// The sheet used to have one way of choosing a day and one answer to what it did: the timeline
/// went there and the sheet STAYED (MEMNG-178), because the heatmap is a scrubber and a sheet that
/// put itself away on every release would be a date field nobody could correct. That is still the
/// right answer for the field — and it left the interaction with no end: the anchored list, with
/// the notice on top of it naming the day, is drawn UNDER the sheet, so the outcome of the whole
/// exercise was the one thing a reader could not see (MEMNG-187).
///
/// So there are two ways of choosing now, and this is what separates them. It is an enum rather
/// than a Bool on a closure because the difference is a decision — the screen reads it once and
/// acts on it — and a decision worth one line is worth pinning with a test.
///
/// It lives beside `SearchPresentation` rather than beside the row that raises it because the
/// presentation is what it acts ON: kept in the view layer, the choice and the sheet it closes
/// could only meet inside a screen no unit test can build, and the one line joining them was
/// deletable with every suite still green (MEMNG-187, review round 1).
public enum SearchDayChoice: Equatable, Sendable {
    /// The finger came off a square, or a date was picked in the field. The timeline moves; the
    /// sheet stays, and the day can be corrected.
    case field(MemoQueryAnchor)
    /// The commit row. The day is settled: the timeline moves and the sheet goes with it, which
    /// is what puts the landing on screen.
    case shown(MemoQueryAnchor)

    /// The day to take the timeline to. Both ways move the list — they differ in nothing else.
    public var anchor: MemoQueryAnchor {
        switch self {
        case .field(let anchor), .shown(let anchor): anchor
        }
    }

    /// Whether choosing this way puts the sheet away.
    public var dismisses: Bool {
        switch self {
        case .field: false
        case .shown: true
        }
    }
}

extension SearchPresentation {
    /// A day was chosen on the sheet: the sheet goes if the day was settled, and stays if it was
    /// only moved.
    ///
    /// The screen calls this INSTEAD of deciding for itself, which is the whole reason it exists.
    /// Written inline in the sheet's closure, the dismissal was a line no test could reach — the
    /// choice's `dismisses` was asserted on one side and the presentation's `close()` on the
    /// other, and deleting the line that joined them left every suite green (MEMNG-187, review
    /// round 1). Taking the timeline to `choice.anchor` stays with the screen: that is the
    /// timeline's own store, not this one's.
    public func chose(_ choice: SearchDayChoice) {
        if choice.dismisses { close() }
    }
}
