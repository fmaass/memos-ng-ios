import MemosCore
import SwiftUI

/// The Collections tab's root (MEMNG-709, MEMNG-713), as the tab hosts it: the session's stores
/// handed to `CollectionsScreen`.
///
/// The trip and member stores are the session's, built once by `MainTabView` and moved
/// to a new identity beside the timeline (`TimelineView`); this view only reads them. The tag
/// list and the year buckets are its own, as the Library's are. With no stores in the
/// environment — a harness that hosts the tabs without a session's — it draws the empty root with
/// nothing it can do.
struct CollectionsRootView: View {
    @Environment(SessionStore.self) private var session: SessionStore?
    @Environment(TripStore.self) private var trips: TripStore?
    @Environment(TripMemberStore.self) private var members: TripMemberStore?
    @Environment(LibraryTagJump.self) private var tagJump: LibraryTagJump?
    @Environment(LibraryYearJump.self) private var yearJump: LibraryYearJump?
    /// The Tags row's names and counts, every kind of file counted.
    @State private var tags: LibraryTagStore?
    /// The Years row's years and counts, every kind of file and every tag counted (MEMNG-720).
    @State private var years: LibraryBucketStore?
    /// The trips pushed onto the tab's stack (MEMNG-714).
    @State private var trail: [TripRoute] = []

    var body: some View {
        Self.stack(trail: $trail) { content }
    }

    /// The tab's stack over `root`: the trips pushed on `trail`, the main bar's room at the root's
    /// foot, and a press on Collections while it shows taking the stack back to the root
    /// (MEMNG-781). A press on another tab, or the one that comes back here, keeps the trail.
    static func stack(
        trail: Binding<[TripRoute]>, @ViewBuilder root: () -> some View
    ) -> some View {
        NavigationStack(path: trail) {
            root()
                // The app's main bar's room, inside the stack (MEMNG-690).
                .leadingFootBar(on: .collections)
        }
        .onTabReselected(.collections) { trail.wrappedValue = [] }
    }

    @ViewBuilder
    private var content: some View {
        if let session, let trips, let members, let tags, let years {
            CollectionsScreen(
                trips: trips,
                members: members,
                tags: tags,
                years: years,
                identity: session.snapshotIdentity,
                access: {
                    guard let handle = session.activeHandle, let baseURL = session.serverBaseURL
                    else { return nil }
                    return CollectionsAccess(handle: handle, baseURL: baseURL)
                },
                openTag: { LibraryJumpRequests.openTag($0, tags: tagJump, years: yearJump) },
                openYear: { LibraryJumpRequests.openYear($0, tags: tagJump, years: yearJump) },
                trail: $trail
            )
            // Another account's tags and years go before anything is read for this one: the whole
            // identity, since the same subject on another server is another account.
            .onChange(of: session.snapshotIdentity) {
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
/// **Cards.** The household's trips as the server lists them (`TripStore.refresh`), in the
/// server's order, each with its cover, title, dates and count. The list is read when the root
/// appears, on pull-to-refresh and when the New trip sheet goes away; while the first read is out
/// the root says so, a failed read with nothing to show says why with Try Again, and an answer
/// with no trip is the empty state. The count is the server's for this account; the cover and
/// dates are the drained members' once read here (`TripMemberStore`, every trip on screen drained
/// when the list or its revision moves, a drain in flight joined), the server's own until then. A
/// card opens its trip (`TripView`), pushed onto the tab's stack.
///
/// **Years.** The year buckets, every kind and every tag counted, newest first — drawn only from a
/// list read for exactly that (`bucketsShown`), so nothing else the store held, nor an empty or
/// failed read, puts a row on screen: no years, no row. A chip opens the Library at that year.
struct CollectionsScreen: View {
    let trips: TripStore
    let members: TripMemberStore
    let tags: LibraryTagStore
    /// The Years row's buckets; with none — a host that reads no years — there is no row.
    var years: LibraryBucketStore? = nil
    /// The Months row's buckets.
    var months: LibraryBucketStore? = nil
    /// The tag cards' covers.
    var tagCovers: TagCoverStore? = nil
    /// Whose root this is — the server and the subject, since the same subject on another server
    /// is another account; a change of either reads it all again.
    let identity: TimelineSnapshotIdentity?
    /// The session's handle and server when a read is issued, or nil when there is none.
    let access: () -> CollectionsAccess?
    /// A tag chip was tapped: the Library opens narrowed to it.
    let openTag: (String) -> Void
    /// A year chip was tapped: the Library opens at that year, in Months.
    var openYear: (String) -> Void = { _ in }
    /// A month card was tapped.
    var openMonth: (String) -> Void = { _ in }
    var now: () -> Date = { Date() }
    /// The trips pushed onto the stack this screen is the root of. A trip that leaves the store —
    /// deleted from its own screen, or filed under an identity that has gone — leaves the stack
    /// with it, here, by the stack's own state: a trip's screen popping itself as its delete
    /// alert goes away is a dismissal the going alert takes for its own.
    var trail: Binding<[TripRoute]> = .constant([])
    /// What a pushed trip's Manage menu runs through; a test hands in its own to drive it.
    var tripManage: () -> TripManage = { TripManage() }

    @State private var newTrip: NewTripFlow?
    /// Each card's last summary, kept while its trip is read again (`HeldTripSummary`).
    @State private var heldSummaries: [String: HeldTripSummary] = [:]
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
    /// What the root says while the first list of trips is read.
    static let loadingTitle = "Reading trips…"
    /// The identifier of that line.
    static let loadingID = "collections-loading"
    /// The failed list's retry.
    static let retryButton = "Try Again"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.section) {
                tripsSection
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
        .refreshable { await refresh() }
        // The Library's header over the root, its + included, with no bar above it: the two tabs
        // read as a pair (MEMNG-757).
        .safeAreaBar(edge: .top) {
            Self.header(
                subtitle: CollectionsPresentation.headerSubtitle(
                    tripCount: trips.trips.count, listFailed: trips.lastError != nil)
            ) { newTrip = NewTripFlow() }
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
        // A card opens its trip inside the tab's stack (MEMNG-714), under the main bar, with
        // its room (MEMNG-715).
        .stackDestination(for: TripRoute.self) { route in
            TripView(
                trip: trips.trips.first { $0.uid == route.id } ?? route.opened,
                trips: trips, memberStore: members, identity: identity, access: access,
                trail: trail, manage: tripManage(), now: now)
        }
        // Back from the sheet the list is read again: one list, whatever the sheet did.
        .sheet(item: $newTrip, onDismiss: { Task { await refresh() } }) { flow in
            NewTripSheet(flow: flow, trips: trips, members: members, access: access, now: now)
        }
        .task(id: identity) { await refresh() }
        // A summary the store answered stands until the next one; another account keeps none.
        .onChange(of: freshSummaries) { _, now in
            let kept = Set(trips.trips.map(\.uid))
            heldSummaries = heldSummaries.filter { kept.contains($0.key) }
                .merging(now) { _, new in new }
        }
        .onChange(of: identity) { heldSummaries = [:] }
        .task(id: identity) { await loadTags() }
        .task(id: identity) { await loadYears() }
        .task(
            id: DrainKey(
                identity: identity, ids: trips.trips.map(\.uid), revision: trips.revision)
        ) {
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
        let subtitle = CollectionsPresentation.headerSubtitle(tripCount: tripCount)
        return header(subtitle: subtitle, newTrip: newTrip)
    }

    /// The header over a subtitle already worded: the count, or that the list was not read.
    static func header(subtitle: String, newTrip: (() -> Void)?) -> some View {
        ScreenHeader(title: MainTab.collections.title, subtitle: subtitle) {
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

    /// The trips, or what stands in for them: the first read on the wire, a failure with nothing
    /// to show, or the empty state.
    @ViewBuilder
    private var tripsSection: some View {
        if let error = trips.lastError {
            VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
                NoticeCard(text: error, tone: .error)
                Button(Self.retryButton) { Task { await refresh() } }
            }
            .padding(.horizontal, DesignTokens.Space.roomy)
        }
        if !trips.trips.isEmpty {
            tripsRow
        } else if trips.isRefreshing {
            HStack(spacing: DesignTokens.Space.snug) {
                ProgressView()
                Text(Self.loadingTitle).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(Self.loadingID)
        } else if trips.lastError == nil {
            Self.emptyState
        }
    }

    private var tripsRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            Text(Self.tripsHeader)
                .font(.title2.bold())
                .padding(.horizontal, DesignTokens.Space.roomy)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DesignTokens.Space.regular) {
                    ForEach(trips.trips) { trip in
                        NavigationLink(value: TripRoute(trip)) {
                            TripCard(
                                trip: trip,
                                cover: CollectionsPresentation.cover(
                                    of: trip, summary: shownSummary(of: trip)),
                                detail: CollectionsPresentation.tripDetail(
                                    trip, summary: shownSummary(of: trip), locale: locale,
                                    timeZone: timeZone)
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

    /// Reads the list of trips; a list already on the wire is joined.
    private func refresh() async {
        guard let access = access() else { return }
        await trips.refresh(using: access.handle, baseURL: access.baseURL)
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

    /// The summaries the store holds now, each with the trip it was read for.
    private var freshSummaries: [String: HeldTripSummary] {
        var fresh: [String: HeldTripSummary] = [:]
        for trip in trips.trips {
            if let summary = members.summary(for: trip) {
                fresh[trip.uid] = HeldTripSummary(trip, summary, under: trips.identity)
            }
        }
        return fresh
    }

    private func shownSummary(of trip: Trip) -> TripMemberSummary? {
        CollectionsPresentation.shownSummary(
            of: trip, store: members.summary(for: trip), held: heldSummaries,
            under: trips.identity)
    }

    /// Every trip's membership, one after another, in the order the cards stand.
    private func drainTrips() async {
        for trip in trips.trips where members.state(for: trip) == .notLoaded {
            if Task.isCancelled { return }
            guard let access = access() else { return }
            await members.drain(trip, using: access.handle, baseURL: access.baseURL)
        }
    }

    private struct DrainKey: Equatable {
        let identity: TimelineSnapshotIdentity?
        let ids: [String]
        let revision: Int
    }
}

/// One trip: its cover, then its title, then its span and count. The card reads no clock.
struct TripCard: View {
    let trip: Trip
    let cover: MemoAttachment?
    let detail: String?

    static let width: CGFloat = 160

    /// The card's identifier when its cover draws `uid`, and when it draws the placeholder.
    static func coverIdentifier(_ uid: String?) -> String {
        uid.map { "trip-card-cover-\($0)" } ?? "trip-card-no-cover"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
            coverImage
                .frame(width: Self.width, height: Self.width)
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
                .padding(.bottom, DesignTokens.Space.tight)
            Text(trip.title)
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
        .accessibilityLabel(trip.title)
        .accessibilityValue(detail ?? "")
        // From the very value `coverImage` draws, so what a test reads is what the card renders.
        .accessibilityIdentifier(Self.coverIdentifier(cover?.uid))
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
