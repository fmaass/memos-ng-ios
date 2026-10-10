import Foundation
import MemosCore
import Observation

/// One opening of the New trip sheet: the tag chosen, the title being written, the span, and how
/// Create ended.
///
/// **The span is prefilled from the tag** (MEMNG-737, the owner's decision A): choosing a tag whose
/// first and last picture are known sets the span to their days, whole, in the phone's zone
/// (`TripSpanDraft.days`), so a trip made the old way also gathers the untagged pictures of those
/// days. A span somebody edited survives another choice, as a typed title does; a trip may also be
/// made of dates alone (`addDates`), or of its tag alone (`removeDates`).
///
/// **Create waits for the prefill.** While the chosen tag's first and last picture are still being
/// read (`awaitingDates`), Create is off, so a quick Create cannot file the trip without the dates
/// decision A gives it. The wait ends when the dates arrive, when the owner says No Dates, or when
/// the chosen tag's own read has ended without them (`endDatesRead(of:)`, a failed read
/// included): the trip is then filed by its tag alone, and its dates can be set later on Trip
/// Dates. Only the chosen tag's read ends the wait — never a read of another tag.
///
/// **Create is read back, never trusted.** `CollectionStore.create` hands back a record whether or
/// not it reached the file — with nobody signed in, or a write that failed, the record exists
/// nowhere else. So the flow looks for it in `records`, the list the file says, and only a record
/// found there closes the sheet; anything else keeps the sheet open with `failure` said under it.
///
/// **One trip per sheet, refused after.** A second Create after one that succeeded is refused, not
/// sent: the store runs two calls one after the other and would file two trips. A Create that
/// failed may be pressed again — nothing of it exists to duplicate.
@MainActor
@Observable
final class NewTripFlow: Identifiable {
    /// The tag the trip is made of, or nil before one is chosen.
    private(set) var chosenTag: String?
    /// The title field, prefilled from the chosen tag.
    var title = ""
    /// The span the trip is filed with, or nil for a trip of its tag alone.
    var span: TripSpanDraft?
    /// The owner chose No Dates: the trip is its tag alone, and no prefill is waited for.
    private(set) var noDates = false
    /// The chosen tag's dates have been read, answered or not — a tag without dated pictures
    /// answers too, and so does a failed read.
    private var datesAnswered = false
    /// Why the last Create did not file a trip, or nil.
    private(set) var failure: String?
    /// The trip this sheet filed, once it has.
    private(set) var created: CollectionRecord?

    /// What the sheet says when the record is not in the store after Create.
    static let notSaved = "The trip could not be saved on this device. Try again."

    /// The suggestion the title field was last filled with, so a title somebody typed survives
    /// choosing another tag and one they left alone follows it.
    @ObservationIgnored private var suggestedTitle = ""
    /// The span last prefilled from a tag, so an edited span survives another choice.
    @ObservationIgnored private var suggestedSpan: TripSpanDraft?

    nonisolated let id = UUID()

    init() {}

    /// Chooses `tag`, and fills the title from it unless somebody has written their own — and the
    /// span from its pictures (`prefill`), when they are known.
    func choose(_ tag: String, span tagSpan: TripTagSpan? = nil, zone: TimeZone = .current) {
        // The same tag again keeps its answer: its read is not asked for twice.
        if tag != chosenTag { datesAnswered = false }
        chosenTag = tag
        failure = nil
        if title.isEmpty || title == suggestedTitle {
            suggestedTitle = TripTitle.suggest(tag)
            title = suggestedTitle
        }
        // A span the last tag prefilled is that tag's; an edited one stays.
        if span == suggestedSpan { clearSuggestedSpan() }
        prefill(tagSpan, of: tag, zone: zone)
    }

    /// Sets the span to the days of the chosen tag's pictures, in `zone` — unless somebody edited
    /// the span, or `tag` is no longer the one chosen. Called again when a tag's span arrives
    /// after it was chosen.
    func prefill(_ tagSpan: TripTagSpan?, of tag: String, zone: TimeZone) {
        guard tag == chosenTag, tagSpan != nil else { return }
        datesAnswered = true
        guard !noDates, span == nil || span == suggestedSpan,
            let first = tagSpan?.firstTaken, let last = tagSpan?.lastTaken,
            let days = TripSpanDraft.days(from: first, to: last, in: zone)
        else { return }
        span = days
        suggestedSpan = days
    }

    /// A span for a trip made of dates: the day of `now`, whole, in `zone`.
    func addDates(now: Date, zone: TimeZone) {
        guard span == nil else { return }
        noDates = false
        span = TripSpanDraft.days(from: now, to: now, in: zone)
    }

    /// No span: the trip is its tag alone, by the owner's choice.
    func removeDates() {
        clearSuggestedSpan()
        noDates = true
    }

    /// The read of `tag`'s dates has ended, answered or not. When `tag` is still the chosen one, a
    /// tag still without dates is filed alone; a read of any other tag changes nothing.
    func endDatesRead(of tag: String) {
        guard tag == chosenTag else { return }
        datesAnswered = true
    }

    /// Whether Create waits for the chosen tag's dates.
    var awaitingDates: Bool {
        chosenTag != nil && span == nil && !noDates && !datesAnswered
    }

    private func clearSuggestedSpan() {
        span = nil
        suggestedSpan = nil
    }

    /// The title as it will be filed: trimmed.
    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether Create has anything to file: a title, a tag or a span, no span that ends before it
    /// starts, and no prefill still awaited.
    var canCreate: Bool {
        guard created == nil, !trimmedTitle.isEmpty, !awaitingDates else { return false }
        if let span { return span.span != nil }
        return chosenTag != nil
    }

    /// Files the trip in `store` and answers it, or nil when nothing was filed — refused, or not
    /// found in the store afterwards (`failure` then says so).
    @discardableResult
    func create(in store: CollectionStore) -> CollectionRecord? {
        guard canCreate else { return nil }
        let record = store.create(
            title: trimmedTitle, tags: chosenTag.map { [$0] } ?? [], span: span?.span)
        guard let filed = store.records.first(where: { $0.id == record.id }) else {
            failure = Self.notSaved
            return nil
        }
        failure = nil
        created = filed
        return filed
    }
}
