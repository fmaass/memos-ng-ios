import Foundation

/// Moving a day between the two calendars a date field lives in.
///
/// A `DatePicker` deals in instants and shows them in the DEVICE's zone; the heatmap's squares and
/// the anchor they become are cut in UTC, because that is the zone Postgres cut the server's day
/// keys in (`HeatmapPresentation`). Handing one to the other unconverted is an off-by-one day for
/// everybody who is not on Greenwich, and it is silent: in Berlin, picking 24 August hands over
/// 2026-08-23T22:00:00Z, whose UTC day is the 23rd, so the field says one day and the timeline
/// shows another.
///
/// Both directions are here, and both are pure, because the round trip is the property that
/// matters: what the picker shows and what the heatmap highlights have to be the same square.
enum SearchDay {
    /// The UTC day a picker's value names — the day a person SAW themselves choose, re-cut in the
    /// calendar the server counts in.
    static func utcDay(from picked: Date, in device: Calendar) -> Date? {
        let parts = device.dateComponents([.year, .month, .day], from: picked)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return nil
        }
        return HeatmapDateJump.anchorCalendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )
    }

    /// The instant a picker has to be handed so that it displays a UTC day as itself.
    ///
    /// `startOfDay` rather than the assembled date, because a zone that skips midnight on the
    /// night it enters daylight saving has no 00:00 to assemble — the date lands an hour in, and
    /// the picker would show the right day for the wrong reason.
    static func pickerDate(for utcDay: Date, in device: Calendar) -> Date? {
        let parts = HeatmapDateJump.anchorCalendar.dateComponents(
            [.year, .month, .day], from: utcDay
        )
        guard let year = parts.year, let month = parts.month, let day = parts.day,
            let assembled = device.date(
                from: DateComponents(year: year, month: month, day: day)
            )
        else { return nil }
        return device.startOfDay(for: assembled)
    }
}
