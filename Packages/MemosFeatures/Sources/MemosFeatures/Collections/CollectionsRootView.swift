import MemosCore
import SwiftUI

/// The Collections tab's root (MEMNG-709, MEMNG-713), as the tab hosts it: the session's stores
/// handed to `CollectionsScreen`.
///
/// The trip and member stores are the session's, built once by `MainTabView` and moved
/// to a new identity beside the timeline (`TimelineView`); this view only reads them. The tag
/// list, the tag covers and the month and year buckets are its own, as the Library's are. With no
/// stores in the
/// environment — a harness that hosts the tabs without a session's — it draws the empty root with
/// nothing it can do.
struct CollectionsRootView: View {
    @Environment(SessionStore.self) private var session: SessionStore?
    @Environment(TripStore.self) private var trips: TripStore?
    @Environment(TripMemberStore.self) private var members: TripMemberStore?
    /// The favorites ledger, when the session's composition provides one: the Favorites card's
    /// counts follow its commits (MEMNG-868).
    @Environment(FavoriteStore.self) private var favorites: FavoriteStore?
    /// The session's picture-tag store, built beside the favorites in `MainTabView`, which
    /// follows them and moves it to a new identity. A host without one gets a store of its own.
    @Environment(PictureTagStore.self) private var sessionPictureTags: PictureTagStore?
    /// The Tags row's names and counts, every kind of file counted.
    @State private var tags: LibraryTagStore?
    /// The Years row's years and counts, every kind of file and every tag counted (MEMNG-720).
    @State private var years: LibraryBucketStore?
    /// The Months row's months and counts, counted as the years are (MEMNG-783). A store of its
    /// own: one store holds one answer, and the years are another.
    @State private var months: LibraryBucketStore?
    /// The tag cards' covers, one lookup per tag (MEMNG-783).
    @State private var covers: TagCoverStore?
    /// The covers chosen for tags, months and years, the household's on the server (MEMNG-842).
    @State private var chosenCovers: CollectionCoverStore?
    /// The pictures' own tags and counts, the Favorites card's (MEMNG-868).
    @State private var pictureTags: PictureTagStore?
    /// The collections pushed onto the tab's stack (MEMNG-714, MEMNG-817).
    @State private var trail: [CollectionRoute] = []

    var body: some View {
        Self.stack(trail: $trail) { content }
    }

    /// The tab's stack over `root`: the trips pushed on `trail`, the main bar's room at the root's
    /// foot, and a press on Collections while the root shows clearing the stack (MEMNG-781) —
    /// over a collection that press brings back its modes row instead (MEMNG-822). The dock is
    /// told the path itself on every change, the one authority for which collection is on top.
    static func stack(
        trail: Binding<[CollectionRoute]>, @ViewBuilder root: () -> some View
    ) -> some View {
        NavigationStack(path: trail) {
            root()
                // The app's main bar's room, inside the stack (MEMNG-690).
                .leadingFootBar(on: .collections)
        }
        .onTabReselected(.collections) { trail.wrappedValue = [] }
        .modifier(CollectionTrailReport(trail: trail.wrappedValue))
    }

    @ViewBuilder
    private var content: some View {
        if let session, let trips, let members, let tags, let years, let months, let covers,
            let pictureTags, let chosenCovers
        {
            CollectionsScreen(
                trips: trips,
                members: members,
                tags: tags,
                years: years,
                months: months,
                tagCovers: covers,
                chosenCovers: chosenCovers,
                pictureTags: pictureTags,
                favorites: favorites,
                identity: session.snapshotIdentity,
                access: {
                    guard let handle = session.activeHandle, let baseURL = session.serverBaseURL
                    else { return nil }
                    return CollectionsAccess(handle: handle, baseURL: baseURL)
                },
                trail: $trail
            )
            // Another account's tags, covers, months and years go before anything is read for this
            // one: the whole identity, since the same subject on another server is another account.
            .onChange(of: session.snapshotIdentity) {
                tags.sessionIdentityChanged()
                years.sessionIdentityChanged()
                months.sessionIdentityChanged()
                covers.sessionIdentityChanged()
                chosenCovers.sessionIdentityChanged()
                pictureTags.sessionIdentityChanged()
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
                    if months == nil {
                        let store = LibraryBucketStore(
                            onUnauthorized: { [session] refusal in await session.handle(refusal) }
                        )
                        store.reports(to: session)
                        months = store
                    }
                    if covers == nil {
                        let store = TagCoverStore(
                            onUnauthorized: { [session] refusal in await session.handle(refusal) }
                        )
                        store.reports(to: session)
                        covers = store
                    }
                    if chosenCovers == nil {
                        let store = CollectionCoverStore(
                            onUnauthorized: { [session] refusal in await session.handle(refusal) }
                        )
                        store.reports(to: session)
                        chosenCovers = store
                    }
                    if pictureTags == nil, let sessionPictureTags {
                        pictureTags = sessionPictureTags
                    }
                    if pictureTags == nil {
                        let store = PictureTagStore(
                            onUnauthorized: { [session] refusal in await session.handle(refusal) }
                        )
                        store.reports(to: session)
                        if let favorites { store.follow(favorites) }
                        pictureTags = store
                    }
                }
        }
    }
}

/// The Collections root: the trips, the tags, the months and the years, each a row of cover cards
/// (`CollectionCard`, MEMNG-783), and `+` for a new trip.
///
/// Everything it reads arrives as a value — the stores, and the session's means of reading as a
/// closure — so a test hosts it over a scripted transport without a session.
///
/// **Cards.** The household's trips as the server lists them (`TripStore.refresh`), in the
/// server's order, each with its cover, title and count. The list is read when the root
/// appears, on pull-to-refresh and when the New trip sheet goes away; while the first read is out
/// the root says so, a failed read with nothing to show says why with Try Again, and an answer
/// with no trip is the empty state. The count is the server's for this account; the cover is
/// the drained members' once read here (`TripMemberStore`, every trip on screen drained
/// when the list or its revision moves, a drain in flight joined), the server's own until then. A
/// card opens its trip (`TripView`), pushed onto the tab's stack.
///
/// **Tags.** The tags with their counts, every kind of file counted — less every tag a listed trip
/// is made of (decision H): a trip's tag is the trip's card. While the list of trips is unread or
/// failed nothing is left out. Each card's cover is its tag's newest picture (`TagCoverStore`). A
/// card opens its collection — the trip's screen over the tag's pictures (MEMNG-817).
///
/// **Months and Years.** The month and the year buckets, every kind and every tag counted, newest
/// first, each from a store of its own and each drawn only from a list read for exactly that, so
/// nothing else the store held, nor an empty or failed read, puts a row on screen: none, no row.
/// A card's cover is its bucket's own, so it costs no request. A month or a year card opens its
/// collection, cut in the zone its bucket was counted in (MEMNG-817).
struct CollectionsScreen: View {
    let trips: TripStore
    let members: TripMemberStore
    let tags: LibraryTagStore
    /// The Years row's buckets; with none — a host that reads no years — there is no row.
    var years: LibraryBucketStore? = nil
    /// The Months row's buckets; with none — a host that reads no months — there is no row.
    var months: LibraryBucketStore? = nil
    /// The tag cards' covers; with none, every tag card is the plain tile.
    var tagCovers: TagCoverStore? = nil
    /// The covers chosen for tags, months and years (MEMNG-842): a card draws its chosen one over
    /// its own, and a collection's Use as Cover writes here. With none, no such choice is offered.
    var chosenCovers: CollectionCoverStore? = nil
    /// The pictures' own tags (MEMNG-868): the Favorites card's count; with none, no such card.
    var pictureTags: PictureTagStore? = nil
    /// The favorites ledger, when there is one: each of its commits reads the counts again.
    var favorites: FavoriteStore? = nil
    /// Whose root this is — the server and the subject, since the same subject on another server
    /// is another account; a change of either reads it all again.
    let identity: TimelineSnapshotIdentity?
    /// The session's handle and server when a read is issued, or nil when there is none.
    let access: () -> CollectionsAccess?
    var now: () -> Date = { Date() }
    /// The trips pushed onto the stack this screen is the root of. A trip that leaves the store —
    /// deleted from its own screen, or filed under an identity that has gone — leaves the stack
    /// with it, here, by the stack's own state: a trip's screen popping itself as its delete
    /// alert goes away is a dismissal the going alert takes for its own.
    var trail: Binding<[CollectionRoute]> = .constant([])
    /// What a pushed trip's Manage menu runs through; a test hands in its own to drive it.
    var tripManage: () -> TripManage = { TripManage() }

    @State private var newTrip: NewTripFlow?
    /// The picture-tag reads, one at a time (`JoinedReads`).
    @State private var pictureTagReads = JoinedReads()
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
    /// The albums' heading, the row under the trips (MEMNG-803).
    static let albumsHeader = "Albums"
    /// The tags' heading.
    static let tagsHeader = "Tags"
    /// The months' heading.
    static let monthsHeader = "Months"
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
                albumsRow
                if !tagRow.isEmpty {
                    tagsRow
                }
                if let shown = monthsShown, !shown.isEmpty {
                    monthsRow(shown)
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
            Self.header { newTrip = NewTripFlow(kind: nil) }
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
        // A card opens its trip inside the tab's stack (MEMNG-714), under the main bar, with
        // its room (MEMNG-715).
        .stackDestination(for: CollectionRoute.self) { route in
            TripView(
                scope: Self.destination(route, in: trips), openedUnder: route.openedUnder,
                trips: trips, memberStore: members, identity: identity, access: access,
                trail: trail, manage: tripManage(), chosenCovers: chosenCovers, now: now)
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
        .task(id: identity) { await pictureTagReads.run { await loadPictureTags() } }
        // Every favorites commit reads the counts again, keyed on the ledger's revision, which
        // moves on each commit. Never on `isStale`: a read can end still stale, after commits
        // that landed while it was out, and a Bool that stays true schedules nothing more.
        // The card's cover is read again too: the commit may have taken its picture away.
        .onChange(of: favorites?.revision ?? 0) {
            Task { await pictureTagReads.run { await loadPictureTags() } }
            tagCovers?.forget(FavoritesCard.subject)
            Task { await loadFavoritesCover() }
        }
        .task(id: identity) { await loadMonths() }
        .task(id: identity) { await loadYears() }
        .task(
            id: DrainKey(
                identity: identity, ids: trips.trips.map(\.uid), revision: trips.revision)
        ) {
            await drainTrips()
        }
    }

    /// What a pushed route's screen opens on: a trip as the store holds it now, or as its card
    /// opened it; an automatic collection as its card opened it.
    static func destination(_ route: CollectionRoute, in trips: TripStore) -> CollectionScope {
        guard let opened = route.opened else { return route.scope }
        return .trip(trips.trips.first { $0.uid == opened.uid } ?? opened)
    }

    /// A tag card's collection: its name, its count and the cover the card shows (MEMNG-817).
    static func tagRoute(
        _ tag: LibraryTag, cover: MemoAttachment?, zone: TimeZone,
        under identity: TimelineSnapshotIdentity?
    ) -> CollectionRoute {
        let collection = AutomaticCollection(
            kind: .tag(tag.name), count: tag.count,
            cover: cover.map { CollectionCover(uid: $0.uid, thumbnailURL: $0.thumbnailURL) },
            zone: zone)
        return CollectionRoute(scope: .automatic(collection), openedUnder: identity)
    }

    /// The Favorites card's collection (MEMNG-868): the pictures carrying the `favorites` picture
    /// tag, never a memo tag's listing; its count and the cover the card shows.
    static func favoritesRoute(
        count: Int, cover: MemoAttachment?, zone: TimeZone,
        under identity: TimelineSnapshotIdentity?
    ) -> CollectionRoute {
        let collection = AutomaticCollection(
            kind: .pictureTag(FavoriteTag.name), count: count,
            cover: cover.map { CollectionCover(uid: $0.uid, thumbnailURL: $0.thumbnailURL) },
            zone: zone)
        return CollectionRoute(scope: .automatic(collection), openedUnder: identity)
    }

    /// A month or a year card's collection, cut in the zone its bucket store answered in — never
    /// the device's, which may count another month — or nil when that zone is unknown or the key
    /// names no period: a route that could never be read is not pushed.
    static func bucketRoute(
        _ kind: AutomaticCollection.Kind, count: Int, coverUid: String, thumbnailURL: URL?,
        answeredZone: String?, under identity: TimelineSnapshotIdentity?
    ) -> CollectionRoute? {
        guard let answeredZone, let zone = TimeZone(identifier: answeredZone) else { return nil }
        let collection = AutomaticCollection(
            kind: kind, count: count,
            cover: thumbnailURL.map { CollectionCover(uid: coverUid, thumbnailURL: $0) },
            zone: zone)
        guard collection.period != nil else { return nil }
        return CollectionRoute(scope: .automatic(collection), openedUnder: identity)
    }

    /// Pushes `route` onto the tab's stack; nothing for a card whose route was refused.
    private func push(_ route: CollectionRoute?) {
        guard let route else { return }
        trail.wrappedValue.append(route)
    }

    /// The root before the session's stores exist: the empty state and a `+` that cannot act.
    static var placeholder: some View {
        ScrollView { emptyState.padding(.vertical, DesignTokens.Space.roomy) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top) { header(newTrip: nil) }
            .toolbarVisibility(.hidden, for: .navigationBar)
    }

    /// The root's header (MEMNG-757): the Library's, the trip count under the title and the `+`
    /// the same glass circle as the Library's options button. With no action — the placeholder's
    /// — the `+` is drawn and cannot act.
    static func header(newTrip: (() -> Void)?) -> some View {
        // No count under the title (the owner, 2026-10-25): a failed list says so in the trips
        // section, over its Try Again.
        ScreenHeader(title: MainTab.collections.title, subtitle: nil) {
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
        if !tripsOnly.isEmpty {
            tripsRow
        } else if !albums.isEmpty {
            // Albums only: their row stands, and the empty state would say nothing is there.
            EmptyView()
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

    /// One row: its heading over a carousel of cards.
    private func row<Item: Identifiable, Card: View>(
        _ header: String, _ items: [Item], @ViewBuilder card: @escaping (Item) -> Card
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            Text(header)
                .font(.title2.bold())
                .padding(.horizontal, DesignTokens.Space.roomy)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DesignTokens.Space.regular) {
                    ForEach(items) { item in card(item) }
                }
                .padding(.horizontal, DesignTokens.Space.roomy)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The listed collections of each kind, in the server's order.
    private var tripsOnly: [Trip] { CollectionsPresentation.trips(of: trips.trips) }
    private var albums: [Trip] { CollectionsPresentation.albums(of: trips.trips) }

    private var tripsRow: some View {
        row(Self.tripsHeader, tripsOnly) { trip in collectionCard(trip) }
    }

    /// The albums under the trips, on the trip's own card: its cover, its title and its count.
    /// With none yet, the row stands with one New Album card, which opens the sheet on Album.
    private var albumsRow: some View {
        row(Self.albumsHeader, CollectionsPresentation.albumRow(albums)) { card in
            switch card {
            case .album(let album): collectionCard(album)
            case .newAlbum: NewAlbumCard { newTrip = NewTripFlow(kind: .album) }
            }
        }
    }

    private func collectionCard(_ trip: Trip) -> some View {
        NavigationLink(value: CollectionRoute(trip, openedUnder: identity)) {
            CollectionCard(
                cover: CollectionsPresentation.cover(of: trip, summary: shownSummary(of: trip)),
                title: trip.title,
                count: trip.memberCount)
        }
        .buttonStyle(.plain)
    }

    /// The cards the row draws: Favorites first while a picture carries it, then the store's
    /// memo tags less every listed trip's tag.
    private var tagRow: [CollectionsPresentation.TagRowCard] {
        CollectionsPresentation.tagRow(
            memoTags: tags.tags,
            pictureTags: pictureTags?.tags ?? [],
            excluding: CollectionsPresentation.tripTags(
                trips.trips, listFailed: trips.lastError != nil))
    }

    private var tagsRow: some View {
        row(Self.tagsHeader, tagRow) { card in
            switch card {
            case .favorites(let count):
                FavoritesCard(count: count, covers: tagCovers, access: access) {
                    push(
                        Self.favoritesRoute(
                            count: count, cover: tagCovers?.cover(of: FavoritesCard.subject),
                            zone: timeZone, under: identity))
                }
            case .tag(let tag):
                let chosen = chosenCovers?.cover(of: .tag(tag.name))
                TagCard(tag: tag, covers: tagCovers, chosen: chosen, access: access) {
                    push(
                        Self.tagRoute(
                            tag, cover: chosen ?? tagCovers?.cover(for: tag.name), zone: timeZone,
                            under: identity))
                }
            }
        }
    }

    /// Reads the pictures' own tags, every kind counted as the memo tags are.
    private func loadPictureTags() async {
        guard let pictureTags, let access = access() else { return }
        await pictureTags.load(for: .all, using: access.handle)
    }

    /// Reads the Favorites card's cover; a lookup of it already on the wire is joined.
    private func loadFavoritesCover() async {
        guard let tagCovers, let access = access() else { return }
        await tagCovers.load(FavoritesCard.subject, using: access.handle, baseURL: access.baseURL)
    }

    /// Reads the list of trips; a list already on the wire is joined.
    private func refresh() async {
        guard let access = access() else { return }
        await trips.refresh(using: access.handle, baseURL: access.baseURL)
        await loadChosenCovers(access)
    }

    /// Reads the covers chosen for tags, months and years: they are the server's, so a refresh
    /// and a reinstall show them again.
    private func loadChosenCovers(_ access: CollectionsAccess) async {
        await chosenCovers?.load(using: access.handle, baseURL: access.baseURL)
    }

    /// What a computed collection's card draws: its chosen cover, else its own.
    static func shownCover(
        _ kind: AutomaticCollection.Kind, chosen: CollectionCoverStore?, own: MemoAttachment?
    ) -> MemoAttachment? {
        chosen?.cover(of: kind) ?? own
    }

    /// Reads the tags; a tag whose cover lookup found nothing is asked again once its card is
    /// back, since the list it belonged to is being read again.
    private func loadTags() async {
        guard let access = access() else { return }
        tagCovers?.forgetMissing()
        await tags.load(for: .all, using: access.handle)
    }

    /// The month buckets the row draws: the store's list only while it answers a month read of
    /// every kind and every tag, else nil.
    private var monthsShown: [LibraryBucket]? {
        months.flatMap { CollectionsPresentation.bucketsShown($0, size: .month) }
    }

    private func monthsRow(_ shown: [LibraryBucket]) -> some View {
        row(Self.monthsHeader, CollectionsPresentation.monthCards(shown)) { month in
            let cover = Self.shownCover(.month(month.key), chosen: chosenCovers, own: month.cover)
            Button {
                push(
                    Self.bucketRoute(
                        .month(month.key), count: month.count, coverUid: cover?.uid ?? "",
                        thumbnailURL: cover?.thumbnailURL,
                        answeredZone: months?.loadedRequest?.timeZoneIdentifier, under: identity))
            } label: {
                CollectionCard(cover: cover, title: month.title, count: month.count)
            }
            .buttonStyle(.plain)
        }
    }

    /// Every month, every kind and every tag, through the store's own fences.
    private func loadMonths() async {
        guard let months, let access = access() else { return }
        await months.load(
            size: .month, filter: .all, tag: nil, using: access.handle, baseURL: access.baseURL)
    }

    /// The year buckets the row draws: the store's list only while it answers a year read of every
    /// kind and every tag, else nil (`bucketsShown`).
    private var yearsShown: [LibraryBucket]? {
        guard let years else { return nil }
        return bucketsShown(
            for: .years, filter: .all, tag: nil, mine: false, visibility: .any,
            timeZoneIdentifier: years.timeZoneIdentifier,
            buckets: years.buckets, answering: years.loadedRequest)
    }

    private func yearsRow(_ shown: [LibraryBucket]) -> some View {
        row(Self.yearsHeader, shown) { year in
            let own = LibraryBucketCover.attachment(for: year)
            let cover = Self.shownCover(.year(year.key), chosen: chosenCovers, own: own)
            Button {
                push(
                    Self.bucketRoute(
                        .year(year.key), count: year.count, coverUid: cover?.uid ?? year.coverUID,
                        thumbnailURL: cover?.thumbnailURL ?? year.coverThumbnailURL,
                        answeredZone: years?.loadedRequest?.timeZoneIdentifier, under: identity))
            } label: {
                CollectionCard(cover: cover, title: year.key, count: year.count)
            }
            .buttonStyle(.plain)
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

/// Tells the dock the Collections stack's path as it stands, from the first frame (MEMNG-822): a
/// reconciliation with the path, never a log of each assignment, and never an appearance.
private struct CollectionTrailReport: ViewModifier {
    let trail: [CollectionRoute]
    @Environment(AppDock.self) private var dock: AppDock?

    func body(content: Content) -> some View {
        content.onChange(of: trail, initial: true) { _, now in
            dock?.collectionTrail(now.map { AnyHashable($0) })
        }
    }
}

/// Reads run one at a time, with at most one more queued (MEMNG-868): a `run` while one is out
/// asks for exactly one read after it, however many such calls arrive, and returns at once. That
/// read is issued after the one out answers, so whatever moved while it was out is read.
@MainActor
final class JoinedReads {
    private var running = false
    private var queued = false

    func run(_ read: @MainActor () async -> Void) async {
        guard !running else {
            queued = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            queued = false
            await read()
        } while queued
    }
}
