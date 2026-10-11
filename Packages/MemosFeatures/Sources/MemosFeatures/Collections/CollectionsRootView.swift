import MemosCore
import SwiftUI

/// The Collections tab's root (MEMNG-709, MEMNG-713), as the tab hosts it: the session's stores
/// handed to `CollectionsScreen`.
///
/// The collection and membership stores are the session's, built once by `MainTabView` and moved
/// to a new identity beside the timeline (`TimelineView`); this view only reads them. The tag
/// list and the year buckets are its own, as the Library's are. With no stores in the
/// environment — a harness that hosts the tabs without a session's — it draws the empty root with
/// nothing it can do.
struct CollectionsRootView: View {
    @Environment(SessionStore.self) private var session: SessionStore?
    @Environment(CollectionStore.self) private var collections: CollectionStore?
    @Environment(TripMembershipStore.self) private var trips: TripMembershipStore?
    @Environment(LibraryTagJump.self) private var tagJump: LibraryTagJump?
    @Environment(LibraryYearJump.self) private var yearJump: LibraryYearJump?
    /// The Tags row's names and counts, every kind of file counted.
    @State private var tags: LibraryTagStore?
    /// The Years row's years and counts, every kind of file and every tag counted (MEMNG-720).
    @State private var years: LibraryBucketStore?
    /// The trips pushed onto the tab's stack (MEMNG-714).
    @State private var trail: [TripRoute] = []

    var body: some View {
        NavigationStack(path: $trail) {
            content
                // The app's main bar's room, inside the stack (MEMNG-690).
                .leadingFootBar(on: .collections)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session, let collections, let trips, let tags, let years {
            CollectionsScreen(
                collections: collections,
                trips: trips,
                tags: tags,
                years: years,
                subject: session.state.user?.subject,
                access: {
                    guard let handle = session.activeHandle, let baseURL = session.serverBaseURL
                    else { return nil }
                    return CollectionsAccess(handle: handle, baseURL: baseURL)
                },
                openTag: { LibraryJumpRequests.openTag($0, tags: tagJump, years: yearJump) },
                openYear: { LibraryJumpRequests.openYear($0, tags: tagJump, years: yearJump) },
                trail: $trail
            )
            // Another account's tags and years go before anything is read for this one.
            .onChange(of: session.state.user?.subject) {
                tags.sessionIdentityChanged()
                years.sessionIdentityChanged()
            }
        } else {
            CollectionsScreen.placeholder
                .task {
                    guard let session else { return }
                    if tags == nil {
                        let store = LibraryTagStore(
                            onUnauthorized: { [session] refusal in await session.handle(refusal) }
                        )
                        store.reports(to: session)
                        tags = store
                    }
                    if years == nil {
                        // Wired to the session exactly as the Library's own bucket store is.
                        let store = LibraryBucketStore(
                            onUnauthorized: { [session] refusal in await session.handle(refusal) }
                        )
                        store.reports(to: session)
                        years = store
                    }
                }
        }
    }
}

/// The Collections root: the trips as a row of cards, the tags as a row of chips, the years as a
/// row of chips, and `+` for a new trip.
///
/// Everything it reads arrives as a value — the stores, and the session's means of reading as a
/// closure — so a test hosts it over a scripted transport without a session.
///
/// **Cards.** In `order`, each with its cover, title, span and count. The span and count are the
/// record's `lastSummary`, so a card renders before anything is read; the cover is the member that
/// summary names, once the membership has been drained here. Every trip on screen is drained when
/// the root appears and whenever the list of trips changes — `TripMembershipStore` joins a drain
/// already in flight, and writes a summary that changed back to the record. A card opens its trip
/// (`TripView`), pushed onto the tab's stack.
///
/// **Years.** The year buckets, every kind and every tag counted, newest first — drawn only from a
/// list read for exactly that (`bucketsShown`), so nothing else the store held, nor an empty or
/// failed read, puts a row on screen: no years, no row. A chip opens the Library at that year.
struct CollectionsScreen: View {
    let collections: CollectionStore
    let trips: TripMembershipStore
    let tags: LibraryTagStore
    /// The Years row's buckets; with none — a host that reads no years — there is no row.
    var years: LibraryBucketStore? = nil
    /// Whose root this is; a change reads it all again.
    let subject: String?
    /// The session's handle and server when a read is issued, or nil when there is none.
    let access: () -> CollectionsAccess?
    /// A tag chip was tapped: the Library opens narrowed to it.
    let openTag: (String) -> Void
    /// A year chip was tapped: the Library opens at that year, in Months.
    var openYear: (String) -> Void = { _ in }
    var now: () -> Date = { Date() }
    /// The trips pushed onto the stack this screen is the root of. A trip that leaves the store —
    /// deleted from its own screen, or filed under an identity that has gone — leaves the stack
    /// with it, here, by the stack's own state: a trip's screen popping itself as its delete
    /// alert goes away is a dismissal the going alert takes for its own.
    var trail: Binding<[TripRoute]> = .constant([])
    /// What a pushed trip's Manage menu runs through; a test hands in its own to drive it.
    var tripManage: () -> TripManage = { TripManage() }

    @State private var newTrip: NewTripFlow?
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    /// What the empty root says.
    static let emptyTitle = "No trips yet"
    /// What it says under that.
    static let emptyDetail = "Tap + to make a trip from one of your tags."
    /// The `+` button's name, read by VoiceOver.
    static let newTripButton = "New Trip"
    /// The trips' heading.
    static let tripsHeader = "Trips"
    /// The tags' heading.
    static let tagsHeader = "Tags"
    /// The years' heading.
    static let yearsHeader = "Years"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.section) {
                if collections.records.isEmpty {
                    Self.emptyState
                } else {
                    tripsRow
                }
                if !tags.tags.isEmpty {
                    tagsRow
                }
                if let shown = yearsShown, !shown.isEmpty {
                    yearsRow(shown)
                }
            }
            .padding(.vertical, DesignTokens.Space.roomy)
        }
        // The whole screen, so the chrome around the root is laid out against the screen and not
        // against the content's own size (MEMNG-605).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The Library's header over the root, its + included, with no bar above it: the two tabs
        // read as a pair (MEMNG-757).
        .safeAreaBar(edge: .top) {
            Self.header(tripCount: collections.records.count) { newTrip = NewTripFlow() }
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
        // A card opens its trip inside the tab's stack (MEMNG-714), under the main bar, with
        // its room (MEMNG-715).
        .stackDestination(for: TripRoute.self) { route in
            TripView(
                record: collections.records.first { $0.id == route.id } ?? route.opened,
                collections: collections, trips: trips, subject: subject, access: access,
                trail: trail, manage: tripManage(), now: now)
        }
        .sheet(item: $newTrip) { flow in
            NewTripSheet(
                flow: flow, collections: collections, trips: trips, access: access, now: now)
        }
        .task(id: subject) { await loadTags() }
        .task(id: subject) { await loadYears() }
        .task(id: DrainKey(subject: subject, ids: collections.records.map(\.id))) {
            await drainTrips()
        }
    }

    /// The root before the session's stores exist: the empty state and a `+` that cannot act.
    static var placeholder: some View {
        ScrollView { emptyState.padding(.vertical, DesignTokens.Space.roomy) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top) { header(tripCount: 0, newTrip: nil) }
            .toolbarVisibility(.hidden, for: .navigationBar)
    }

    /// The root's header (MEMNG-757): the Library's, the trip count under the title and the `+`
    /// the same glass circle as the Library's options button. With no action — the placeholder's
    /// — the `+` is drawn and cannot act.
    static func header(tripCount: Int, newTrip: (() -> Void)?) -> some View {
        ScreenHeader(
            title: MainTab.collections.title,
            subtitle: CollectionsPresentation.headerSubtitle(tripCount: tripCount)
        ) {
            HeaderGlassCircle(systemName: "plus", label: newTripButton) { newTrip?() }
                .disabled(newTrip == nil)
        }
    }

    private static var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: MainTab.collections.symbol)
        } description: {
            Text(emptyDetail)
        }
    }

    private var tripsRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            Text(Self.tripsHeader)
                .font(.title2.bold())
                .padding(.horizontal, DesignTokens.Space.roomy)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DesignTokens.Space.regular) {
                    let pinned = collections.activePin(now: now())?.id
                    ForEach(collections.records) { record in
                        NavigationLink(value: TripRoute(record)) {
                            TripCard(
                                record: record,
                                cover: cover(of: record),
                                detail: CollectionsPresentation.cardDetail(
                                    record.lastSummary, locale: locale, timeZone: timeZone),
                                pinned: record.id == pinned
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DesignTokens.Space.roomy)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var tagsRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            Text(Self.tagsHeader)
                .font(.title2.bold())
                .padding(.horizontal, DesignTokens.Space.roomy)
            ScrollView(.horizontal) {
                LazyHStack(spacing: DesignTokens.Space.snug) {
                    ForEach(tags.tags) { tag in
                        TagChip(tag: tag) { openTag(tag.name) }
                    }
                }
                .padding(.horizontal, DesignTokens.Space.roomy)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The card's cover: the chosen one while it is still a member, else the first member, as
    /// the trip's hero draws it.
    private func cover(of record: CollectionRecord) -> MemoAttachment? {
        CollectionsPresentation.cover(
            of: record, live: trips.summary(for: record), members: trips.members(for: record))
    }

    private func loadTags() async {
        guard let access = access() else { return }
        await tags.load(for: .all, using: access.handle)
    }

    /// The year buckets the row draws: the store's list only while it answers a year read of every
    /// kind and every tag, else nil (`bucketsShown`).
    private var yearsShown: [LibraryBucket]? {
        guard let years else { return nil }
        return bucketsShown(
            for: .years, filter: .all, tag: nil, timeZoneIdentifier: years.timeZoneIdentifier,
            buckets: years.buckets, answering: years.loadedRequest)
    }

    private func yearsRow(_ shown: [LibraryBucket]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            Text(Self.yearsHeader)
                .font(.title2.bold())
                .padding(.horizontal, DesignTokens.Space.roomy)
            ScrollView(.horizontal) {
                LazyHStack(spacing: DesignTokens.Space.snug) {
                    ForEach(shown) { year in
                        YearChip(year: year) { openYear(year.key) }
                    }
                }
                .padding(.horizontal, DesignTokens.Space.roomy)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Every year, every kind and every tag, through the store's own fences: a read for a session
    /// that has been replaced is refused, and its answer dropped.
    private func loadYears() async {
        guard let years, let access = access() else { return }
        await years.load(
            size: .year, filter: .all, tag: nil, using: access.handle, baseURL: access.baseURL)
    }

    /// Every trip's membership, one after another, in the order the cards stand.
    private func drainTrips() async {
        for record in collections.records {
            if Task.isCancelled { return }
            guard let access = access() else { return }
            await trips.drain(record, using: access.handle, baseURL: access.baseURL)
        }
    }

    private struct DrainKey: Equatable {
        let subject: String?
        let ids: [UUID]
    }
}

/// One trip: its cover, then its title, then its span and count. While the trip is the scope's
/// active pin a `pin.fill` badge stands in the cover's top trailing corner, and VoiceOver hears
/// "Pinned" before the detail. Whether it is pinned is the host's to say (`activePin(now:)` on the
/// host's clock); the card reads no clock.
struct TripCard: View {
    let record: CollectionRecord
    let cover: MemoAttachment?
    let detail: String?
    var pinned = false

    static let width: CGFloat = 160
    /// What VoiceOver hears for a pinned card, ahead of its detail.
    static let pinnedValue = "Pinned"

    /// The card's identifier when its cover draws `uid`, and when it draws the placeholder.
    static func coverIdentifier(_ uid: String?) -> String {
        uid.map { "trip-card-cover-\($0)" } ?? "trip-card-no-cover"
    }

    /// The card's accessibility value: "Pinned" (when pinned) and the detail, in that order.
    static func accessibilityValue(detail: String?, pinned: Bool) -> String {
        [pinned ? pinnedValue : nil, detail].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
            coverImage
                .frame(width: Self.width, height: Self.width)
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
                .overlay(alignment: .topTrailing) {
                    if pinned { pinBadge }
                }
                .padding(.bottom, DesignTokens.Space.tight)
            Text(record.title)
                .font(.headline)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record.title)
        .accessibilityValue(Self.accessibilityValue(detail: detail, pinned: pinned))
        // From the very value `coverImage` draws, so what a test reads is what the card renders.
        .accessibilityIdentifier(Self.coverIdentifier(cover?.uid))
    }

    /// The pin glyph, white on the accent in a small circle, inset from the cover's corner.
    private var pinBadge: some View {
        Image(systemName: "pin.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(DesignTokens.Space.tight)
            .background(DesignTokens.accent, in: .circle)
            .padding(DesignTokens.Space.tight)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let cover {
            AttachmentThumbnail(
                attachment: cover,
                tier: .thumb,
                slot: AttachmentSlot(aspectRatio: 1, contentMode: .fill)
            )
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "suitcase")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One year: its name and how many files fall in it. A tap opens the Library at that year.
struct YearChip: View {
    let year: LibraryBucket
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: DesignTokens.Space.tight) {
                Text(year.key)
                    .font(.subheadline.weight(.medium))
                Text("\(year.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.Space.regular)
            .padding(.vertical, DesignTokens.Space.snug)
            .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(year.key)
        .accessibilityValue(bucketCountLabel(year.count))
    }
}

/// One tag: its name and how many files carry it. A tap opens the Library narrowed to it.
struct TagChip: View {
    let tag: LibraryTag
    let open: () -> Void

    /// What a chip says for `name`.
    static func label(_ name: String) -> String { "#\(name)" }

    var body: some View {
        Button(action: open) {
            HStack(spacing: DesignTokens.Space.tight) {
                Text(Self.label(tag.name))
                    .font(.subheadline.weight(.medium))
                Text("\(tag.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.Space.regular)
            .padding(.vertical, DesignTokens.Space.snug)
            .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        // As drawn, "#" included — which is also what tells it apart from the same tag's row on
        // the New trip sheet over it.
        .accessibilityLabel(Self.label(tag.name))
        .accessibilityValue(bucketCountLabel(tag.count))
    }
}
