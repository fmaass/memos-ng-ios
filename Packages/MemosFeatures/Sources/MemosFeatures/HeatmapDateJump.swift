import Foundation
import MemosCore

/// What a tap on a heatmap square means.
enum HeatmapDayTap: Equatable, Sendable {
    /// Take the timeline to this day.
    case jump(MemoQueryAnchor)
    /// Nothing at all — a day with no memos under it, or a cell whose key is not a day.
    case ignore
}

/// Turning a tap on an activity square into a jump to that day, and saying which day the timeline
/// has been taken to.
///
/// The decision is a function rather than a closure inside the grid because the interesting part of
/// it is what does NOT happen: a square with nothing under it must not move the timeline at all. A
/// dead jump — the list reloading to show the same emptiness the square already showed — is worse
/// than a tap that is ignored, and it is exactly the case a hand test never reaches.
enum HeatmapDateJump {
    /// The calendar this jump's anchor is read in, and it is the SERVER's, not the device's.
    ///
    /// `GET /api/stats/heatmap` keys its counts by the day Postgres cut in its own zone, which on
    /// this estate is UTC (`HeatmapPresentation`). The anchor a tap produces is a bound on
    /// `created_at`, so reading it in the device's zone would put the bound at the wrong instant:
    /// in Berlin, a square for the 24th would cut at 22:00Z on the 24th and hide the very memos
    /// written between then and midnight UTC — the ones that square was counting. So the store the
    /// timeline jumps with is built with this calendar (`TimelineView`).
    static var anchorCalendar: Calendar { HeatmapPresentation.dayCalendar }

    /// What a tap on this square does.
    ///
    /// The count is the authority, not the level: level 0 IS count 0 today, but a bucket boundary
    /// is a display decision and this is not one.
    ///
    /// The count gate belongs to THIS decision only, and it is the one thing the scrubber does not
    /// inherit (MEMNG-178). A bare tap that reloaded the timeline to show the same emptiness the
    /// square already showed was a dead jump — nothing on screen would have explained it. A scrub
    /// is not that: the square it passes over is written into a visible date field, so an empty
    /// day is a date the reader can see they chose, and the list under it is the nearest older
    /// content with the anchor notice on top saying which day was asked for.
    static func tap(on cell: HeatCell) -> HeatmapDayTap {
        guard cell.count > 0, let anchor = anchor(for: cell) else { return .ignore }
        return .jump(anchor)
    }

    /// The day a square stands for, whether or not anything was written on it.
    ///
    /// Round-tripped rather than merely parsed. `Calendar.date(from:)` ROLLS OVER out-of-range
    /// components — a "2026-13-40" key comes back as a real day in February 2027 — so parsing
    /// alone would happily anchor the timeline to a day nobody has ever seen a square for.
    static func anchor(for cell: HeatCell) -> MemoQueryAnchor? {
        let calendar = anchorCalendar
        guard let day = HeatmapPresentation.day(for: cell.date, calendar: calendar),
            HeatmapPresentation.key(for: day, calendar: calendar) == cell.date
        else { return nil }
        return anchor(for: day)
    }

    /// The anchor a day becomes, read in the calendar the server keys its days in.
    static func anchor(for day: Date) -> MemoQueryAnchor? {
        let parts = anchorCalendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else {
            return nil
        }
        return .day(year: year, month: month, day: dayOfMonth)
    }

    /// A day as the server keys it — the key the grid indexes its squares by, so that a day chosen
    /// in the date field lights the square that stands for it.
    static func key(for day: Date) -> String {
        HeatmapPresentation.key(for: day, calendar: anchorCalendar)
    }

    /// What VoiceOver reads on a square that can be tapped. The grid as a whole says how much the
    /// household wrote; a square that is a control has to say which day it would open.
    static func label(for cell: HeatCell, locale: Locale = .current) -> String {
        let memos =
            switch cell.count {
            case 0: "no memos"
            case 1: "1 memo"
            default: "\(cell.count) memos"
            }
        return "\(text(for: cell.day, locale: locale)), \(memos)"
    }

    /// What the timeline says about itself while it is anchored — the day it was taken to, so the
    /// list looking unfamiliar is explained rather than merely true.
    static func title(for anchor: MemoQueryAnchor, locale: Locale = .current) -> String {
        switch anchor {
        case .day(let year, let month, let day):
            let components = DateComponents(year: year, month: month, day: day)
            guard let date = anchorCalendar.date(from: components) else {
                return "Jumped to " + String(format: "%04d-%02d-%02d", year, month, day)
            }
            return "Jumped to " + text(for: date, locale: locale)
        case .month(let year, let month):
            let components = DateComponents(year: year, month: month, day: 1)
            guard let date = anchorCalendar.date(from: components) else {
                return "Jumped to " + String(format: "%04d-%02d", year, month)
            }
            return "Jumped to " + text(for: date, month: true, locale: locale)
        }
    }

    /// A day in the short form the sheet's commit row names it by: the month and the day, and no
    /// year at all.
    ///
    /// The row is about a day inside the twelve weeks the grid draws — a destination a few screens
    /// down the list the reader is already looking at — and a year on it reads as an anniversary
    /// rather than as somewhere to go. Cut in the same calendar as everything else here, for the
    /// same reason: a date formatted in the device's zone under a square cut in UTC is off by one
    /// for half the day, for everybody who is not on Greenwich.
    static func shortText(for day: Date, locale: Locale = .current) -> String {
        let calendar = anchorCalendar
        var style = Date.FormatStyle().month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(style.locale(locale))
    }

    /// A day (or a month) written out, in the calendar the heatmap's keys are cut in — a date
    /// formatted in the device's zone under a square cut in UTC is the same off-by-one twice.
    private static func text(for day: Date, month: Bool = false, locale: Locale) -> String {
        let calendar = anchorCalendar
        var style = month ? Date.FormatStyle().month(.wide).year() : dayStyle
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(style.locale(locale))
    }

    private static var dayStyle: Date.FormatStyle {
        Date.FormatStyle().day().month(.wide).year()
    }
}
