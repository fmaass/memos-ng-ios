import Foundation
import MemosCore

/// What the sheet knows about the days it can offer.
///
/// The grid under the date field is a WINDOW — twelve weeks — while the store behind it holds a
/// count for every day the account has ever written anything on (`HeatmapStore.counts`, all
/// history). Two of the things the sheet has to say are therefore questions the window cannot
/// answer: how many memos the chosen day holds, and how far back a day may be chosen at all.
///
/// Both are asked of this, and it is a value rather than a lookup in the view so that the answers
/// can be asserted — above all the two that are silent when they are wrong.
struct SearchDayCounts: Equatable, Sendable {
    /// Days to memo counts, keyed exactly as the server keys them.
    let byDay: [String: Int]
    /// The last day that can be chosen, cut in the server's calendar.
    let today: Date
    /// Whether `byDay` is the server's ANSWER rather than the emptiness in front of one.
    ///
    /// Empty counts are two different accounts and nothing else here can tell them apart: one the
    /// server has not answered for yet, and one it answered for with nothing at all (a household
    /// on its first day). Read as the first, the second is a sheet that says nothing about today
    /// and offers a picker running back to the oldest square it happens to be drawing — days that
    /// hold nothing and never did. It is the store's `hasLoaded` and not its section phase: a
    /// FAILED read counts as answered for drawing (`SearchSectionPhase`) and is exactly the case
    /// that must not claim an emptiness (MEMNG-187, review round 1).
    let loaded: Bool

    init(byDay: [String: Int], today: Date, loaded: Bool) {
        self.byDay = byDay
        self.today = HeatmapDateJump.anchorCalendar.startOfDay(for: today)
        self.loaded = loaded
    }

    /// The first day the account has anything on, or nil while nothing is known.
    ///
    /// ISO day keys sort lexicographically in the order they happened, so the earliest key is the
    /// first day with activity — the same comparison `HeatmapPresentation` clamps its window with.
    var firstActivity: Date? {
        guard let earliest = byDay.keys.min() else { return nil }
        return HeatmapPresentation.day(for: earliest)
    }

    /// The earliest day these counts can say anything about at all.
    ///
    /// The first day with activity, and for an answered account with no activity it is TODAY —
    /// which is the whole of what such an account has: a day it is living through and has written
    /// nothing on yet. Before the answer there is no such day, and that nil is what keeps every
    /// sentence below from being invented.
    private var firstCovered: Date? {
        if let first = firstActivity { return first }
        return loaded ? today : nil
    }

    /// How many memos were written on a day, or nil when this cannot say.
    ///
    /// Nil is not zero and the difference is the point. Zero is a day the account lived through
    /// and wrote nothing on; nil is a day outside what the counts cover — before the first memo,
    /// after today, or any day at all before the server has answered — and a row that said "no
    /// memos" there would be inventing an emptiness it has no evidence for (MEMNG-175's mistake,
    /// one row down).
    func count(on day: Date) -> Int? {
        let day = HeatmapDateJump.anchorCalendar.startOfDay(for: day)
        guard let first = firstCovered, day >= first, day <= today else { return nil }
        return byDay[HeatmapDateJump.key(for: day)] ?? 0
    }

    /// The days the date field may offer, in the server's calendar.
    ///
    /// The lower bound is the account's first day, and it is a correctness bound rather than a
    /// nicety: the timeline anchors by asking for memos created BEFORE the chosen day
    /// (`MemoQueryAnchor.createdBefore`), so a day picked before the first memo there is commits
    /// into a feed with nothing in it at all — the one case where the "nearest earlier memos"
    /// landing has no memos to land on (MEMNG-187).
    ///
    /// - Parameter earliestDrawn: the oldest day the grid draws, which stands in until the counts
    ///   land. Without it the field would be locked to today alone for as long as the read takes.
    ///   It stands in for an UNANSWERED read only: an account the server answered with nothing has
    ///   one offerable day, today, and falling back to the grid there would offer twelve weeks of
    ///   days that hold nothing and never did.
    func offerableDays(earliestDrawn: Date?) -> ClosedRange<Date> {
        let calendar = HeatmapDateJump.anchorCalendar
        let start = firstCovered ?? earliestDrawn.map { calendar.startOfDay(for: $0) } ?? today
        return min(start, today)...today
    }

    /// The same range as the picker has to be handed it: a `DatePicker` deals in instants it shows
    /// in the DEVICE's zone, and the bound of a day read in the wrong calendar is a bound on the
    /// day before or after (`SearchDay`).
    func pickerRange(earliestDrawn: Date?, in device: Calendar = .current) -> ClosedRange<Date> {
        let days = offerableDays(earliestDrawn: earliestDrawn)
        let lower = SearchDay.pickerDate(for: days.lowerBound, in: device) ?? days.lowerBound
        let upper = SearchDay.pickerDate(for: days.upperBound, in: device) ?? days.upperBound
        return lower <= upper ? lower...upper : upper...upper
    }
}

/// The sheet's one verb, and the words on it.
///
/// A scrub and a picked date move a field. Nothing said what to do when the day was right, so the
/// only way out was the Done button — which reads as abandoning the search rather than as taking
/// it (MEMNG-187). This row is the verb, and its label is the OUTCOME rather than the action:
/// "Show Jun 12 · 4 memos" says what closing the sheet will leave on screen, which is the one
/// thing the sheet was covering up.
///
/// Pure, because the label is where the three states of the count are decided and each of them is
/// a sentence that can be wrong in a way no screenshot shows.
enum SearchDayCommit {
    /// What the row says, and whether there is anything behind it.
    enum Row: Equatable {
        /// A day to show, and the words on the row.
        case show(anchor: MemoQueryAnchor, label: String)
        /// Nothing to show — no day chosen, or a day the calendar cannot name. The row is drawn
        /// disabled rather than removed: a row that appeared only once a day was chosen would
        /// move everything under it the moment a finger landed on the grid (MEMNG-176).
        case idle(label: String)

        var label: String {
            switch self {
            case .show(_, let label), .idle(let label): label
            }
        }

        /// The day this row would show, or nil for a row that does nothing.
        var anchor: MemoQueryAnchor? {
            switch self {
            case .show(let anchor, _): anchor
            case .idle: nil
            }
        }
    }

    static func row(for day: Date?, count: Int?, locale: Locale = .current) -> Row {
        guard let day, let anchor = HeatmapDateJump.anchor(for: day) else {
            return .idle(label: "Choose a day")
        }
        return .show(anchor: anchor, label: label(for: day, count: count, locale: locale))
    }

    /// The words on the row: the day, and what is on it when that is known.
    ///
    /// An unknown count says the day alone rather than guessing at it — and the row still commits,
    /// because the timeline can answer a question about a day the heatmap has no counts for.
    static func label(for day: Date, count: Int?, locale: Locale = .current) -> String {
        let date = HeatmapDateJump.shortText(for: day, locale: locale)
        guard let count else { return "Show \(date)" }
        let memos =
            switch count {
            case ..<1: "no memos"
            case 1: "1 memo"
            default: "\(count) memos"
            }
        return "Show \(date) · \(memos)"
    }
}
