import Foundation
import MemosCore
import SwiftUI

/// The trip a new memo is offered: today's trip (MEMNG-781, decision 3) — the title the chip shows
/// and the tag the memo is given.
///
/// A VALUE handed into the sheet by whoever presents it, decided once from the store when the
/// sheet is built. The sheet never reads the store: the trips are read at the instant the capture
/// is opened, and a test builds the offer it wants instead of a store and a date.
///
/// The offer carries the instant it ends (MEMNG-765), because a sheet can stay open across it: the
/// sheet compares the clock with that instant when the chip is drawn and when Post is pressed.
public struct ComposePinnedTrip: Equatable, Sendable {
    public var title: String
    public var tag: String
    /// The first instant the offer no longer holds — the start of the day after the span's last
    /// day, in the span's own zone — or nil for an offer that never ends.
    public var endsAt: Date?

    public init(title: String, tag: String, endsAt: Date? = nil) {
        self.title = title
        self.tag = tag
        self.endsAt = endsAt
    }

    /// Whether the offer still holds at `now`: every instant before its end, and every instant
    /// at all for an offer without one.
    public func holds(at now: Date) -> Bool {
        endsAt.map { now < $0 } ?? true
    }

    /// What a new memo opened at `now` is offered: the tagged trip whose span holds today, or
    /// nothing.
    ///
    /// Today is `now`'s day in the span's OWN zone (`Trip.tripSpan`), and the span's first and
    /// last days count whole — a trip ending at 09:00 is still offered at 18:00 that day, which
    /// is when the evening's pictures are posted. A trip with no span, or with no tag (it has
    /// nothing to add to a memo), is never offered, so a span-only trip never hides a tagged one.
    /// Of several, the one begun latest (the more particular trip inside a longer one); equal
    /// starts, the one ending first; equal both, the smaller uid — never the list's order.
    public static func offered(among trips: [Trip], now: Date) -> ComposePinnedTrip? {
        let holding = trips.compactMap { trip -> (Trip, TripSpan, String, Date)? in
            // An end that cannot be computed is no offer, never an offer without an end.
            guard let tag = trip.tag, !tag.isEmpty, let span = trip.tripSpan,
                holdsToday(span, now: now), let end = offerEnd(of: span)
            else { return nil }
            return (trip, span, tag, end)
        }
        let chosen = holding.min { lhs, rhs in
            if lhs.1.start != rhs.1.start { return lhs.1.start > rhs.1.start }
            if lhs.1.end != rhs.1.end { return lhs.1.end < rhs.1.end }
            return lhs.0.uid < rhs.0.uid
        }
        return chosen.map { ComposePinnedTrip(title: $0.0.title, tag: $0.2, endsAt: $0.3) }
    }

    /// The offer over the store's current list — nothing while the list has not answered, and
    /// nothing with no store.
    public static func offered(from store: TripStore?, now: Date) -> ComposePinnedTrip? {
        store.flatMap { offered(among: $0.trips, now: now) }
    }

    /// Whether `now`'s day, in the span's zone, is one of the span's days.
    private static func holdsToday(_ span: TripSpan, now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = span.timeZone
        let today = calendar.startOfDay(for: now)
        return calendar.startOfDay(for: span.start) <= today
            && today <= calendar.startOfDay(for: span.end)
    }

    /// The instant the offer of `span` ends: the start of the day after its last day, in its
    /// zone — the first instant `holdsToday` no longer counts. A calendar day, never 86 400
    /// seconds: the day a zone leaves summer time is 25 hours long.
    private static func offerEnd(of span: TripSpan) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = span.timeZone
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: span.end))
    }
}

/// The chip one compose sheet shows, and what it does to the words that are posted.
///
/// Only a NEW memo gets one: the offer is for captures, and an edit is never offered it whatever
/// it was handed. The ✕ is this sheet's alone — it is state of the sheet, so a new sheet with the
/// same trip starts with the chip back, and the trip itself is never written.
///
/// The tag is added to the SUBMISSION, never to the editor: the words on screen stay what was
/// typed, and a post that failed and is tried again builds its content afresh from them — the
/// line cannot be added twice, and `appendingPinnedTag` leaves a text already carrying the tag
/// (a restored capture, or a writer who typed it) exactly as it is.
struct ComposeTripChip: Equatable {
    private let trip: ComposePinnedTrip?
    private(set) var isDismissed = false

    init(mode: ComposeView.Mode, offered: ComposePinnedTrip?) {
        if case .create = mode {
            trip = offered
        } else {
            trip = nil
        }
    }

    /// The trip the chip shows at `now`, or nil when there is no chip: none was offered, its ✕
    /// was pressed, or the offer has ended since the sheet opened.
    func shown(at now: Date) -> ComposePinnedTrip? {
        guard !isDismissed, let trip, trip.holds(at: now) else { return nil }
        return trip
    }

    /// The ✕: no chip and no tag for the rest of this sheet.
    mutating func dismiss() { isDismissed = true }

    /// The content a Post pressed at `now` sends for `text`, the editor's words as they stand.
    func submittedContent(_ text: String, at now: Date) -> String {
        guard let shown = shown(at: now) else { return text }
        return appendingPinnedTag(shown.tag, to: text)
    }
}

/// The visibility one compose sheet posts with, and whether the offer or the person put it there.
///
/// A trip post is for the two of us and never for the digest, so a NEW memo opened while a trip
/// is offered starts on "Just us" (protected) instead of the account default. The account default
/// itself stays what it is: most posts are not trip posts. That start is the offer's SUGGESTION and
/// it is kept apart from a CHOICE — the chip's ✕ takes an untouched suggestion back to the account
/// default along with the tag, but once the person has set the pill, to anything, "Default"
/// included, it is theirs and nothing the chip does overrides it.
///
/// Only a fresh capture is preselected. An edit states no visibility at all — who sees a memo is
/// changed on purpose, never as a side effect of a trip — and a restored capture keeps the one it
/// was stopped with, which was decided when it was first written.
struct ComposeVisibilityPick: Equatable {
    /// What the post states, or nil for the account default.
    private(set) var selection: MemoVisibility?
    /// Whether `selection` is still the offer's suggestion rather than the person's choice.
    private(set) var isSuggested = false

    init(mode: ComposeView.Mode, offered: ComposePinnedTrip?) {
        switch mode {
        case .create(.some(let restored)):
            selection = restored.visibility
        case .create(.none):
            if offered != nil {
                selection = .protected
                isSuggested = true
            }
        case .edit(_, _, _, _, let visibility):
            // The memo's own audience, never "Default": a memo that exists already has one.
            selection = visibility
        }
    }

    /// What the pill shows and writes. Every write is the person choosing.
    var chosen: MemoVisibility? {
        get { selection }
        set {
            selection = newValue
            isSuggested = false
        }
    }

    /// The chip's ✕: a suggestion nobody touched goes back to the account default; a choice stays.
    mutating func tripRemoved() {
        guard isSuggested else { return }
        selection = nil
        isSuggested = false
    }
}

/// The chip itself: the offered trip's title and the ✕ that leaves its tag off this memo.
struct ComposeTripChipView: View {
    let trip: ComposePinnedTrip
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.tight) {
            Image(systemName: "pin.fill")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(trip.title)
                .lineLimit(1)
                .accessibilityLabel("Trip, \(trip.title)")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove trip tag")
        }
        .font(.subheadline)
        .foregroundStyle(DesignTokens.accent)
        .padding(.horizontal, DesignTokens.Space.regular)
        .padding(.vertical, DesignTokens.Space.tight)
        .background(DesignTokens.accent.opacity(0.12), in: Capsule())
    }
}
