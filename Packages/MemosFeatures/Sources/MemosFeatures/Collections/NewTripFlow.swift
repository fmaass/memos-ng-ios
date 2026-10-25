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
/// **Create is the server's.** Create freezes the form — title, tag, span and zone — into one
/// `NewTripRequest` with one idempotency key, and sends it (`TripStore.create`). While it is out
/// the sheet is busy; only the trip the server answered closes it. A failure keeps the sheet open
/// with `failure` said under the title, and Create again RE-SENDS the frozen request, key and
/// all, so a create the server did take but whose answer was lost is not filed twice. Editing the
/// form after a failure makes a new request with a new key.
///
/// **Bound to its account.** The request carries the identity it was frozen under; when the
/// session becomes somebody else's while it is out, the flow is abandoned — the sheet closes with
/// no result and nothing is retried under the new identity.
///
/// **Trip or Album first** (MEMNG-803; the owner, 2026-10-13: "trips have a date, album dont").
/// A flow opened by the root's + asks which (`kind` nil) before anything else; a flow made for
/// a kind already known starts on it. An album is its title alone: no tag, no span, no prefill.
///
/// **One trip per sheet, refused after.** A second Create after one that succeeded, or while one is
/// out, is refused and sends nothing.
@MainActor
@Observable
final class NewTripFlow: Identifiable {
    /// What the sheet makes, or nil while its first step still asks.
    private(set) var kind: Trip.Kind?
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
    private(set) var created: Trip?
    /// The request Create last sent, with its key; sent again by a retry of the same form.
    private(set) var frozen: NewTripRequest?
    /// Whether a Create is out.
    private(set) var isCreating = false
    /// The account changed while the sheet was up: it closes, and nothing is sent again.
    private(set) var abandoned = false

    /// What the sheet says when Create failed without a reason of its own.
    static let notSaved = "The trip could not be saved. Try again."

    /// The suggestion the title field was last filled with, so a title somebody typed survives
    /// choosing another tag and one they left alone follows it.
    @ObservationIgnored private var suggestedTitle = ""
    /// The span last prefilled from a tag, so an edited span survives another choice.
    @ObservationIgnored private var suggestedSpan: TripSpanDraft?
    /// The tags listed trips are made of, as last told (`drop`), so a Create that fails can
    /// still let go of a tag that became one while it was out.
    @ObservationIgnored private var excluded: Set<String> = []

    nonisolated let id = UUID()

    /// A flow on `kind`, or one that asks first when it is nil.
    init(kind: Trip.Kind? = .trip) {
        self.kind = kind
    }

    /// The first step's answer. Asked once: a kind already chosen stays.
    func choose(kind chosen: Trip.Kind) {
        guard kind == nil else { return }
        kind = chosen
    }

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

    /// The chosen tag became one of `excluded` — a listed trip is made of it now — so it is no
    /// longer chosen, and the title and span it filled go with it; a title somebody typed and a
    /// span somebody edited stay. A Create done keeps its tag, and so does a Create out until it
    /// ends: one that fails lets go of it then, against the exclusions told last.
    func drop(_ excluded: Set<String>) {
        self.excluded = excluded
        dropExcludedTag()
    }

    private func dropExcludedTag() {
        guard let tag = chosenTag, excluded.contains(tag), created == nil, !isCreating else {
            return
        }
        chosenTag = nil
        datesAnswered = false
        failure = nil
        if title == suggestedTitle { title = "" }
        suggestedTitle = ""
        if span == suggestedSpan { clearSuggestedSpan() }
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

    /// Whether Create has anything to file: a kind, a title, and for a trip a tag or a span, no
    /// span that ends before it starts and no prefill still awaited; no Create out or done.
    var canCreate: Bool {
        guard let kind, created == nil, !isCreating, !abandoned, !trimmedTitle.isEmpty else {
            return false
        }
        if kind == .album { return true }
        guard !awaitingDates else { return false }
        if let span { return span.span != nil }
        return chosenTag != nil
    }

    /// The request the form makes under `scope`: the one sent last while the form still says the
    /// same — a retry re-sends it whole, key and all — else a new one with a new key.
    func request(under scope: TimelineSnapshotIdentity) -> NewTripRequest {
        if self.kind == .album {
            if let frozen, frozen.scope == scope, frozen.kind == .album,
                frozen.title == trimmedTitle
            {
                return frozen
            }
            return NewTripRequest(scope: scope, title: trimmedTitle, kind: .album)
        }
        let span = span?.span
        if let frozen, frozen.scope == scope, frozen.kind == .trip, frozen.title == trimmedTitle,
            frozen.tag == chosenTag, frozen.spanStart == span?.start,
            frozen.spanEnd == span?.end, frozen.tz == span?.zone
        {
            return frozen
        }
        return NewTripRequest(
            scope: scope, title: trimmedTitle, kind: .trip, tag: chosenTag,
            spanStart: span?.start, spanEnd: span?.end, tz: span?.zone)
    }

    /// Sends the trip to the server and answers it, or nil when nothing was filed — refused, failed
    /// (`failure` then says why), or abandoned because the account changed while it was out.
    @discardableResult
    func create(in trips: TripStore, using access: CollectionsAccess?) async -> Trip? {
        guard canCreate else { return nil }
        guard let access, let scope = trips.identity else {
            failure = Self.notSaved
            return nil
        }
        let request = request(under: scope)
        frozen = request
        isCreating = true
        let trip: Trip
        do {
            trip = try await trips.create(request, using: access.handle, baseURL: access.baseURL)
        } catch TripStore.Failure.superseded {
            isCreating = false
            abandon()
            return nil
        } catch {
            isCreating = false
            failure = TripManage.sentence(error) ?? Self.notSaved
            // A tag that became a trip's while this Create was out goes now that none is out.
            dropExcludedTag()
            return nil
        }
        isCreating = false
        failure = nil
        created = trip
        return trip
    }

    /// The account changed: the sheet closes with no result, and nothing is sent again.
    func abandon() {
        abandoned = true
        failure = nil
    }
}
