import MemosCore
import SwiftUI

/// The day the search is pointed at, and when that day becomes a request.
///
/// The two are separate on purpose, and the separation IS the debounce (MEMNG-178). A finger
/// crossing twelve weeks of squares produces a reading per frame; committing each one would fire
/// eighty-odd anchored reloads for a gesture whose only meaningful moment is where it stopped. So
/// a scrub moves the field and nothing else, and the query goes out when the finger comes off.
/// That is a debounce with no timer in it — the gesture's own end is the settle — which is why it
/// can be asserted here rather than waited for.
///
/// A day picked in the date field has no gesture to end, so it commits at once.
@MainActor
@Observable
final class SearchDaySelection {
    /// The chosen day, at its start in the calendar the server keys its days in.
    ///
    /// It starts at today rather than at nothing so the field and the grid agree from the moment
    /// the sheet opens: the field says a date, and the square that date names is lit. A field that
    /// began blank would have to invent a "no day" state that the picker below it cannot show.
    private(set) var day: Date

    /// Whether a scrub is in progress. Without it, a finger that never moved onto a square — a
    /// touch that began and ended on the card's padding — would commit the day that was already
    /// there and reload the timeline for nothing.
    private var scrubbing = false

    init(today: Date = .now) {
        day = HeatmapDateJump.anchorCalendar.startOfDay(for: today)
    }

    /// The square drawn as selected, as the server keys it.
    var selectedKey: String { HeatmapDateJump.key(for: day) }

    /// The finger has moved onto a day. Live, and ONLY live.
    func scrub(to day: Date) {
        scrubbing = true
        self.day = HeatmapDateJump.anchorCalendar.startOfDay(for: day)
    }

    /// The finger has come off: the one moment in a scrub that becomes a request.
    ///
    /// - Returns: the anchor to take the timeline to, or nil when no scrub happened.
    @discardableResult
    func endScrub() -> MemoQueryAnchor? {
        guard scrubbing else { return nil }
        scrubbing = false
        return HeatmapDateJump.anchor(for: day)
    }

    /// A day chosen in the date field, read in the DEVICE's calendar and re-cut in the server's.
    @discardableResult
    func pick(_ picked: Date, in device: Calendar = .current) -> MemoQueryAnchor? {
        guard let day = SearchDay.utcDay(from: picked, in: device) else { return nil }
        scrubbing = false
        self.day = day
        return HeatmapDateJump.anchor(for: day)
    }

    /// The chosen day as the picker has to be handed it, so that it displays that day as itself.
    func pickerDate(in device: Calendar = .current) -> Date {
        SearchDay.pickerDate(for: day, in: device) ?? day
    }
}

/// The date field, with the heatmap under it as its scrubber.
///
/// Until MEMNG-178 the grid was a set of eighty-four buttons that each did something invisible: a
/// tap reloaded the timeline somewhere, and nothing on screen said where or that a day was a thing
/// you could choose at all. The field is what the grid now moves, so the grid explains itself —
/// and the field is editable in its own right, so a day too far back to be on the grid is still
/// reachable.
struct SearchDateScrubber: View {
    let grid: HeatmapGrid
    @Binding var expanded: Bool
    /// Takes the timeline to a day. Called on the end of a scrub and on a picked date, never
    /// while a finger is moving.
    let commit: (MemoQueryAnchor) -> Void

    @State private var selection = SearchDaySelection()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            SearchDateRow(day: picked)
            HeatmapCard(
                grid: grid,
                expanded: $expanded,
                scrubbing: HeatmapScrubbing(
                    selectedKey: selection.selectedKey,
                    move: { selection.scrub(to: $0.day) },
                    end: {
                        if let anchor = selection.endScrub() { commit(anchor) }
                    }
                )
            )
        }
    }

    /// The picker writes through the selection rather than into it: the day it hands back is read
    /// in the device's zone and has to be re-cut in the server's before it means anything, and the
    /// commit is the picker's own — there is no gesture end to wait for.
    private var picked: Binding<Date> {
        Binding(
            get: { selection.pickerDate() },
            set: { picked in
                if let anchor = selection.pick(picked) { commit(anchor) }
            }
        )
    }
}

/// The field itself: a label and the day, tappable to edit.
///
/// Its own view because it is measured — the row puts a flexible gap between the two ends, and a
/// flexible gap reports back whatever width it is offered rather than the width the row needs.
struct SearchDateRow: View {
    @Binding var day: Date

    var body: some View {
        HStack(spacing: DesignTokens.Space.snug) {
            Label {
                Text("Date").font(.subheadline)
            } icon: {
                Image(systemName: "calendar")
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: DesignTokens.Space.snug)
            DatePicker("Date", selection: $day, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
        .padding(DesignTokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Date")
        .accessibilityHint("The day the timeline is taken to")
    }
}
