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
    /// The day the interface SHOWS: the scrub under the finger when there is one, else the last
    /// day that actually became a request. Split so that a gesture the system cancels can roll
    /// the display back instead of leaving the field naming a day the timeline never went to
    /// (review round).
    var day: Date { pending ?? committed }

    /// The last day that was committed — shown whenever no finger is down. Starts at today so the
    /// field and the grid agree from the moment the sheet opens.
    private var committed: Date

    /// The day under a finger mid-scrub, or nil when no scrub is in progress. Its nil-ness also
    /// keeps a touch that never reached a square from committing anything.
    private var pending: Date?

    init(today: Date = .now) {
        committed = HeatmapDateJump.anchorCalendar.startOfDay(for: today)
    }

    /// The square drawn as selected, as the server keys it.
    var selectedKey: String { HeatmapDateJump.key(for: day) }

    /// The finger has moved onto a day. Live, and ONLY live.
    func scrub(to day: Date) {
        pending = HeatmapDateJump.anchorCalendar.startOfDay(for: day)
    }

    /// The finger has come off: the one moment in a scrub that becomes a request.
    ///
    /// - Returns: the anchor to take the timeline to, or nil when no scrub happened.
    @discardableResult
    func endScrub() -> MemoQueryAnchor? {
        guard let pending else { return nil }
        self.pending = nil
        committed = pending
        return HeatmapDateJump.anchor(for: pending)
    }

    /// The system took the gesture away — a call, an interruption, the sheet moving. Nothing
    /// commits and the display falls back to the committed day, so the field never names a day
    /// the timeline is not on. After a normal end this is a no-op: the commit already cleared
    /// the pending day.
    func cancelScrub() {
        pending = nil
    }

    /// A day chosen in the date field, read in the DEVICE's calendar and re-cut in the server's.
    @discardableResult
    func pick(_ picked: Date, in device: Calendar = .current) -> MemoQueryAnchor? {
        guard let day = SearchDay.utcDay(from: picked, in: device) else { return nil }
        pending = nil
        committed = day
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
    /// Whether the counts under the scrubber are the server's answer yet — threaded through to
    /// the card, which draws a waiting grid greyed, inert and at its final size (MEMNG-175/176).
    var phase: SearchSectionPhase = .ready

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
                    },
                    cancelled: { selection.cancelScrub() }
                ),
                phase: phase
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
