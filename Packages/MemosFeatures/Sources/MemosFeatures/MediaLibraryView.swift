import MemosCore
import SwiftUI

/// The media library: everything the household has posted, as a grid, one cursor page at a time.
///
/// It is the SPA's Resources tab brought over (`frontend/src/views/ResourcesView.vue`) — the same
/// three filters, the same newest-first order, the same lightbox on tap — laid out the way a phone
/// lays out a library: square tiles in a grid that adapts to the width, rather than the justified
/// rows a wide browser window can afford.
///
/// Nothing here loads an image itself. A tile is an `AttachmentThumbnail`, which is the timeline's
/// tile, so the library and the feed share one loader, one cache and one set of rules about
/// signatures and retries; and a tap opens `MediaViewerView` through the same projection a memo's
/// photos open through. A second image path for the same files is the one thing this screen must
/// not become.
struct MediaLibraryView: View {
    @Environment(SessionStore.self) private var session
    @State private var library: MediaLibraryStore?
    /// The tags the options menu offers, with picture counts for the kind on screen (MEMNG-513).
    @State private var tags: LibraryTagStore?
    /// The year and day buckets the Years and Months views are drawn from (MEMNG-586).
    @State private var buckets: LibraryBucketStore?
    /// Which of Years, Months and All is on screen, and the year a Years card narrowed Months to.
    /// Shared with the dock, whose segment picks it (plan page 3929 decision 11); a Library hosted
    /// with no dock above it keeps its own, at All.
    @Environment(LibraryScopeChoice.self) private var sharedChoice: LibraryScopeChoice?
    @State private var ownChoice = LibraryScopeChoice()
    /// The dock this Library's scrolling collapses to its segment, when there is one above it.
    @Environment(AppDock.self) private var dock: AppDock?
    /// The media a tile tap opened, full screen.
    @State private var viewing: MediaViewerSelection?
    /// The download a tile's menu starts, and the sheet it ends in.
    @State private var saving = MediaSaveFlow()
    /// What the zoom transition matches the viewer to: the tile it grew out of.
    @Namespace private var mediaZoom
    /// Which direction this device reads the library in, across launches. Read once, when the
    /// store is built, and written whenever the menu is used — the store is what the screen reads
    /// the current direction FROM, so there is only ever one answer on screen.
    private let preferences = LibraryPreferences.shared

    var body: some View {
        NavigationStack {
            Group {
                if let library {
                    content(library)
                } else {
                    ProgressView()
                }
            }
            .background(Color(.systemGroupedBackground))
            // One header over All, Years and Months alike, and nothing over the grid below it:
            // the kind, the sort and the tag are chosen in its options menu (page 3929 decision 5).
            .safeAreaBar(edge: .top) {
                if let library { header(library) }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            // INSIDE the stack, while the viewer's cover is outside it: two presentations declared
            // on one view is how one of them silently stops appearing, and this screen now has
            // both a cover and a sheet.
            .fetchingFile(saving)
        }
        // Outside the stack, for the reason the timeline's cover is: two presentations on one view
        // is how one of them silently stops appearing.
        .fullScreenCover(item: $viewing) { selection in
            // The viewer pages over the STORE, not over the rows that happened to be loaded when
            // the tile was tapped: swiping to the end of them is where the swiping used to stop,
            // on a library of over a thousand files (MEMNG-189).
            MediaViewerView(selection: selection, source: viewerSource)
                .mediaZoomTransition(sourceID: selection.id, in: mediaZoom)
        }
        .tint(DesignTokens.accent)
        .task {
            if library == nil {
                library = MediaLibraryStore(
                    order: preferences.order,
                    onUnauthorized: { [session] refusal in
                        await session.handle(refusal)
                    }
                )
            }
            if tags == nil {
                tags = LibraryTagStore(
                    onUnauthorized: { [session] refusal in
                        await session.handle(refusal)
                    }
                )
            }
            if buckets == nil {
                buckets = LibraryBucketStore(
                    onUnauthorized: { [session] refusal in
                        await session.handle(refusal)
                    }
                )
            }
            // A choice made in the dock's segment abandons a jump still reading, synchronously, on
            // the store it is reading on.
            if let library {
                choice.whenChosenByHand { [weak library] in library?.abandonJump() }
            }
            // A failure that never reached the server belongs to the session's one banner, not to
            // an error card over this grid (`SessionReporting`).
            library?.reports(to: session)
            tags?.reports(to: session)
            buckets?.reports(to: session)
            await load()
        }
        // The buckets are read when Years or Months comes on screen, again whenever the kind or
        // the tag changes — their counts are counts under both — and again for whoever is signed
        // in now. All reads none.
        .task(
            id: BucketListKey(
                scope: choice.scope,
                filter: library?.filter,
                tag: library?.tag,
                subject: session.state.user?.subject
            )
        ) {
            await loadBuckets()
        }
        // The tag list is read when the Library appears, again whenever the kind changes — its
        // counts are counts under that kind — and again for whoever is signed in now.
        .task(id: TagListKey(filter: library?.filter, subject: session.state.user?.subject)) {
            await loadTags()
        }
        // The rows on this grid belong to the account they were read as. If the session becomes
        // somebody else's — or nobody's — while the tab is up, they go, the way the timeline's do.
        .onChange(of: session.state.user?.subject) {
            library?.sessionIdentityChanged()
            tags?.sessionIdentityChanged()
            buckets?.sessionIdentityChanged()
        }
        // The server is answering again, and this grid was read while it was not.
        .reloadsOnRecovery(session.reachabilityRecoveries) {
            await load()
            await loadBuckets()
        }
    }

    /// What the full-screen viewer reads. `.fixed` only when there is no store yet, which is a
    /// state no tap can be made in — the grid it would be tapped on does not exist either.
    private var viewerSource: MediaViewerSource {
        Self.viewerSource(for: library) { await loadMore() }
    }

    /// The same decision, as a function, so what this screen hands the viewer is a thing a test can
    /// hold rather than infer from a view body: the source must be `.library` over the very store
    /// the grid is reading, or the viewer pages through a copy and stops at its end.
    static func viewerSource(
        for library: MediaLibraryStore?,
        more: @MainActor @escaping () async -> Void
    ) -> MediaViewerSource {
        guard let library else { return .fixed([]) }
        return .library(library, more: more)
    }

    private var choice: LibraryScopeChoice { sharedChoice ?? ownChoice }

    @ViewBuilder
    private func content(_ library: MediaLibraryStore) -> some View {
        switch choice.scope {
        case .all:
            grid(library)
        case .years, .months:
            if let buckets {
                bucketContent(library, buckets)
            } else {
                ProgressView()
            }
        }
    }

    /// Years and Months: the buckets under the same header, the view on screen drawn only from a
    /// list read for it (`bucketsShown`).
    @ViewBuilder
    private func bucketContent(
        _ library: MediaLibraryStore,
        _ store: LibraryBucketStore
    ) -> some View {
        // Nil while the store's list answers some other selection — a read still on its way, or
        // one that failed and left the previous kind's list standing.
        let scope = choice.scope
        let year = choice.year
        let answered = bucketsShown(
            for: scope,
            filter: library.filter,
            tag: library.tag,
            timeZoneIdentifier: store.timeZoneIdentifier,
            buckets: store.buckets,
            answering: store.loadedRequest
        )
        let shown = answered ?? []
        Group {
            if scope == .years {
                LibraryYearsGrid(
                    years: shown,
                    errorText: store.lastError,
                    chooseYear: { chooseYear($0) }
                )
                .feedsDock(dock, on: .library)
            } else {
                LibraryMonthsMosaic(
                    months: mosaicMonths(year.map { dayBuckets(shown, inYear: $0) } ?? shown),
                    year: year,
                    errorText: store.lastError,
                    clearYear: { choice.clearYear() },
                    showDay: { showDay($0) },
                    target: answered == nil ? nil : choice.monthTarget,
                    reachedTarget: { choice.consumeMonthTarget() }
                )
                .feedsDock(dock, on: .library)
            }
        }
        .overlay {
            if shown.isEmpty {
                if store.isLoading {
                    ProgressView()
                } else if answered != nil, store.lastError == nil {
                    ContentUnavailableView(
                        "Nothing Here",
                        systemImage: "photo.on.rectangle",
                        description: Text("No pictures fall on any date under this filter.")
                    )
                }
            }
        }
        .refreshable { await loadBuckets(refreshing: true) }
    }

    /// A Years card opens that year's days in the Months view, narrowed on the device from the one
    /// list of day buckets, the way the web does.
    private func chooseYear(_ key: String) {
        choice.showMonths(of: key)
    }

    /// A day tile's tap: the All grid, landed on that day (MEMNG-587). The segment moves at once;
    /// the store reads until it holds the day and names the row the grid scrolls to
    /// (`MediaLibraryStore.landing`). The day is looked for in the zone the bucket was counted in.
    private func showDay(_ day: LibraryBucket) {
        guard let library, let buckets else { return }
        let zone = buckets.timeZoneIdentifier
        choice.showAll()
        Task { await jump(library, toDay: day.key, in: zone) }
    }

    @ViewBuilder
    private func grid(_ library: MediaLibraryStore) -> some View {
        LibraryGrid(
            items: library.items,
            errorText: library.lastError,
            loadingMore: library.isLoadingMore,
            zoom: mediaZoom,
            wantsMore: { library.shouldLoadMore(after: $0) },
            open: { open($0) },
            fetch: { file, rendition in await fetch(file, rendition) },
            loadMore: { await loadMore() },
            landing: library.landing,
            landed: { library.consumeLanding($0) },
            // Asked where it is acted on, never remembered from the last drawing: the store can
            // replace the list between a drawing and a geometry callback already on its way.
            listGeneration: { library.listGeneration },
            dayBuckets: buckets.flatMap { store in
                bucketsShown(
                    for: .all,
                    filter: library.filter,
                    tag: library.tag,
                    timeZoneIdentifier: store.timeZoneIdentifier,
                    buckets: store.buckets,
                    answering: store.loadedRequest
                )
            },
            showMonth: { choice.showMonth($0) }
        )
        .feedsDock(dock, on: .library)
        .overlay {
            if library.isJumping {
                ProgressView()
            } else if let empty = MediaLibraryPresentation.emptyOverlay(
                itemsEmpty: library.items.isEmpty,
                isLoading: library.isLoading,
                lastError: library.lastError,
                filter: library.filter,
                tag: library.tag
            ) {
                ContentUnavailableView(
                    empty.title,
                    systemImage: empty.symbol,
                    description: Text(empty.message)
                )
            }
        }
        .refreshable { await refreshAll() }
    }

    /// All's pull-to-refresh: the list and the day buckets its headings count from, read side by
    /// side, so a day that gained a picture is not drawn under its old count. The buckets go
    /// through the store's refreshing read, so a read still pending from before the pull cannot
    /// answer for it.
    private func refreshAll() async {
        async let list: Void = load()
        async let counts: Void = loadBuckets(refreshing: true)
        _ = await (list, counts)
    }

    /// The title, the line naming what the grid holds, and the options menu that changes it.
    private func header(_ library: MediaLibraryStore) -> some View {
        LibraryHeader(
            subtitle: MediaLibraryPresentation.subtitle(
                filter: library.filter,
                order: library.order,
                tag: library.tag
            )
        ) {
            LibraryOptionsMenuContent(
                order: sortBinding(library),
                filter: filterBinding(library),
                tag: tagBinding(library),
                tagRows: tagRows(library)
            )
        }
    }

    /// Choosing a kind resets the paging (`setFilter`) and reads the first page of the kind that
    /// was chosen, as the segmented bar it replaces did; the tags and the buckets follow through
    /// their task keys, which name the kind. A menu row can be chosen again while it is already
    /// the choice, and that is no change: it must not start a second read of the same page.
    private func filterBinding(_ library: MediaLibraryStore) -> Binding<MediaLibraryFilter> {
        Binding(
            get: { library.filter },
            set: { chosen in
                guard chosen != library.filter else { return }
                library.setFilter(chosen)
                Task { await load() }
            }
        )
    }

    private func tagRows(_ library: MediaLibraryStore) -> [LibraryTagRow] {
        MediaLibraryPresentation.tagRows(tags?.tags ?? [], selected: library.tag)
    }

    private func tagBinding(_ library: MediaLibraryStore) -> Binding<String?> {
        Binding(
            get: { library.tag },
            set: { chosen in
                guard chosen != library.tag else { return }
                library.setTag(chosen)
                Task { await load() }
            }
        )
    }

    /// Choosing a direction persists it and reloads the grid from the other end — the store treats
    /// it exactly as it treats a tab change, because a cursor is a position inside one ordering.
    private func sortBinding(_ library: MediaLibraryStore) -> Binding<MediaLibraryOrder> {
        Binding(
            get: { library.order },
            set: { chosen in
                guard chosen != library.order else { return }
                preferences.select(chosen)
                library.setOrder(chosen)
                Task { await load() }
            }
        )
    }

    /// Opens the viewer over the WHOLE library, at the tile that was tapped — and, because the
    /// viewer reads the store rather than a snapshot of it, a swipe carries on past the rows that
    /// were loaded at the moment of the tap.
    private func open(_ attachment: MemoAttachment) {
        guard let library else { return }
        viewing = MediaViewerPresentation.viewer(
            for: library.items.map(\.attachment),
            startingAt: attachment.uid
        )
    }

    /// Fetches the named file of a tile's attachment and offers it to the share sheet. The
    /// credential the original tier needs is the session's, and it stays there (see
    /// `OriginalMedia`).
    private func fetch(_ attachment: MemoAttachment, _ rendition: AttachmentRendition) async {
        await saving.save(attachment) { [session] file in
            try await session.download(file, rendition)
        }
    }

    private func load() async {
        guard let library, let handle = session.activeHandle,
            let baseURL = session.serverBaseURL
        else { return }
        await library.refresh(using: handle, baseURL: baseURL)
    }

    /// Reads the tags under the kind on screen, and widens the grid back to every tag when the
    /// chosen one is not among them (`MediaLibraryStore.dropTagIfAbsent`).
    private func loadTags() async {
        guard let library, let tags, let handle = session.activeHandle else { return }
        await tags.load(for: library.filter, using: handle)
        if library.dropTagIfAbsent(from: tags) { await load() }
    }

    /// Reads the buckets the view on screen is drawn from, under the kind and tag the grid is
    /// narrowed to. `refreshing` is a pull-to-refresh, which a read already pending does not
    /// answer for.
    private func loadBuckets(refreshing: Bool = false) async {
        guard let library, let buckets, let size = choice.scope.bucketSize,
            let handle = session.activeHandle, let baseURL = session.serverBaseURL
        else { return }
        if refreshing {
            await buckets.refresh(
                size: size,
                filter: library.filter,
                tag: library.tag,
                using: handle,
                baseURL: baseURL
            )
        } else {
            await buckets.load(
                size: size,
                filter: library.filter,
                tag: library.tag,
                using: handle,
                baseURL: baseURL
            )
        }
    }

    private func loadMore() async {
        guard let library, let handle = session.activeHandle,
            let baseURL = session.serverBaseURL
        else { return }
        await library.loadMore(using: handle, baseURL: baseURL)
    }

    private func jump(_ library: MediaLibraryStore, toDay day: String, in zone: String) async {
        guard let handle = session.activeHandle, let baseURL = session.serverBaseURL else { return }
        await library.jump(toDay: day, in: zone, using: handle, baseURL: baseURL)
    }
}

/// The scrolling grid itself, split from the screen so a test can host it.
///
/// `MediaLibraryView` reads `SessionStore` from the environment, which the test bundle cannot
/// build — the reason `TimelineView` and `SettingsView` are not hosted in tests either. The grid
/// is where MEMNG-206 lived: nothing asserted that a store full of files ever became PLACED
/// tiles, so the width round-trip could break with every unit around it green. Everything the
/// grid draws arrives as a value; the session, the store and the fetching stay in the screen.
/// What the tag list is read again on: the kind on screen and the account it is read as.
private struct TagListKey: Equatable {
    let filter: MediaLibraryFilter?
    let subject: String?
}

/// What the bucket list is read again on: the view on screen, the kind and tag its counts are
/// counted under, and the account it is read as.
private struct BucketListKey: Equatable {
    let scope: LibraryScope
    let filter: MediaLibraryFilter?
    let tag: String?
    let subject: String?
}

/// What the grid asks again on for a landing: the landing, the width its rows are solved to, and
/// each layout and each row built while the landing's row is not yet among them.
private struct LandingReadiness: Equatable {
    let landing: LibraryLanding?
    let width: CGFloat
    let laidOut: CGFloat
    let built: Int
}

/// The rows a grid's lazy stack has built now, kept out of SwiftUI's observation (`LibraryGrid`).
final class RowsOnScreen {
    var rows: Set<String> = []
}

struct LibraryGrid: View {
    let items: [LibraryRow]
    /// What the store last failed with, shown at the top of the scroll.
    let errorText: String?
    /// Whether the next page is on its way — the spinner at the bottom of the scroll.
    let loadingMore: Bool
    /// The screen's zoom namespace: the viewer's transition grows out of the tile it matches.
    let zoom: Namespace.ID
    /// Whether the file at this index is near enough the end to fetch the next page. The trigger
    /// is the store's, not this view's: how close to the end is close enough is a rule with its
    /// own vectors, not a number in a view body.
    let wantsMore: (Int) -> Bool
    let open: (MemoAttachment) -> Void
    /// Fetch one of a file's renditions and offer it — the menu's two slow actions, as one
    /// closure, because they differ only in which file they ask for.
    let fetch: (MemoAttachment, AttachmentRendition) async -> Void
    let loadMore: () async -> Void
    /// The row a jump to a day landed on, which the scroll is brought to each time a jump lands.
    /// The store takes it down with the list it belongs to, so an abandoned jump never lands here.
    var landing: LibraryLanding?
    /// Told once the scroll has been brought to `landing`'s built row, so it is scrolled to once.
    var landed: (LibraryLanding) -> Void = { _ in }
    /// Which list `items` is now (`MediaLibraryStore.listGeneration`), read live: a heading a
    /// landing held belongs to the list it landed in, and a filter, order or tag change is
    /// another list.
    var listGeneration: () -> Int = { 0 }
    /// The day buckets a heading's count is read from, or nil while none answer this list
    /// (`MediaLibraryPresentation.dayCount`).
    var dayBuckets: [LibraryBucket]?
    /// The date pill's tap: Months at this `YYYY-MM` month (plan page 3929 decision 13).
    var showMonth: (String) -> Void = { _ in }
    /// The way to a memo from a tab that cannot open one. Optional: a preview or a test host has
    /// no router, and a missing environment value must be a missing action, not a crash.
    @Environment(MemoJump.self) private var jump: MemoJump?
    /// How wide the rows are solved for — the scroll's own width, less the padding. Measured
    /// rather than assumed, so a rotation or a split view re-packs the library rather than
    /// running it off the edge.
    @State private var contentWidth: CGFloat = 0
    /// The landing this grid has brought its scroll to: a width measured again afterwards must not
    /// bring the reader back to it.
    @State private var scrolledTo: LibraryLanding?
    /// The heading a landing brought to the line, held there until the reader's own hand moves
    /// the scroll. Each time the lazy stack measures rows it has not built yet, the scroll is put
    /// back where its estimate says — for a heading on the first screen, the top of the page — so
    /// reaching the line once does not keep it there. It belongs to the list it landed in
    /// (`listGeneration`): a next page keeps it, any other list lets it go.
    @State private var holding: (heading: String, listGeneration: Int)?
    /// The rows the lazy stack has built now, the ones on or beside the screen. A reference rather
    /// than observed state on purpose: it changes with every row scrolled past, and observing it
    /// would re-solve the whole library each time.
    @State private var onScreen = RowsOnScreen()
    /// The height the rows were last laid out to, kept only while a landing waits to be reached,
    /// so the library is not re-solved for every layout after that.
    @State private var laidOut: CGFloat = 0
    /// How many rows the lazy stack has built while a landing waits to be reached.
    @State private var built = 0
    /// The day the date pill names, read only by the pill, so a scroll re-draws the pill and not
    /// the library.
    @State private var pill = DatePillModel()
    /// Where each built heading and band starts on the page, for the pill. A reference for the
    /// reason `onScreen` is one.
    @State private var markers = DayMarkers()

    var body: some View {
        // Hoisted because the measuring closure below is `Sendable` and may run off the main
        // actor, where the design tokens are not reachable.
        let inset = 2 * DesignTokens.Space.tight
        ScrollViewReader { proxy in
            scroll(inset: inset)
                // Asked when the grid appears — the Months tap builds a new grid, and the landing
                // may already be there — and again whenever the landing or the measured width
                // moves, because before the width is known no row exists to scroll to.
                .onChange(of: readiness, initial: true) { bring(proxy) }
                // And again each time the rows are laid out anew: a scroll to a row the lazy stack
                // has not built goes where its estimate puts it, which moves as rows are measured.
                // No delay stands in for this: the layout, and the rows built, say when to ask.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height
                } action: { _, laid in
                    hold(proxy)
                    guard landing != nil, landing != scrolledTo else { return }
                    laidOut = laid
                }
                // The line under the header, in the page's own coordinates: the day whose marker
                // has reached it is the day at the top of the screen. Every move shows the pill
                // and starts its one-second fade again (`DatePillModel`).
                .onScrollGeometryChange(for: PageLine.self) { geometry in
                    PageLine(geometry)
                } action: { _, line in
                    markers.line = line
                    pill.scrolled(to: topDay(markers.inOrder, threshold: line.y + 1))
                    // A landing still waiting asks again whenever the scroll moves: its heading is
                    // reached only once the scroll has actually brought it to the line.
                    bring(proxy)
                    hold(proxy)
                }
                // The reader's own scroll lets go of the landing's heading.
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        holding = nil
                    }
                }
                .overlay(alignment: .top) {
                    DatePill(model: pill, showMonth: showMonth)
                        .padding(.top, DesignTokens.Space.snug)
                }
        }
    }

    private var readiness: LandingReadiness {
        LandingReadiness(
            landing: landing, width: contentWidth, laidOut: laidOut, built: built)
    }

    /// Scrolls to the landing's day heading, again as often as asked until the lazy stack has built
    /// it: each ask lands nearer, and only a built heading's place is exact rather than estimated.
    private func bring(_ proxy: ScrollViewProxy) {
        guard let landing, landing != scrolledTo, let heading = headingID(holding: landing.rowID)
        else { return }
        // A new landing takes over from the one held before it.
        holding = nil
        proxy.scrollTo(heading, anchor: .top)
        // Built AND at the line — or the scroll at its end, when too little follows the heading
        // for it to rise that far. A heading built on the first screen is built before the scroll
        // can move, so being built alone does not say the scroll went there.
        if onScreen.rows.contains(heading), markers.reached(heading) {
            settle(landing)
            holding = (heading, listGeneration())
        }
    }

    /// Brings the held heading back to the line whenever a layout has moved the scroll off it.
    private func hold(_ proxy: ScrollViewProxy) {
        guard let holding, !markers.reached(holding.heading) else { return }
        // Judged against the list it was taken in, asked of the store here, with nothing between
        // the question and the scroll: after a filter, tag or order change the store has dropped
        // the landing, and the same day in the new list is not the reader's to be brought back to.
        guard holding.listGeneration == listGeneration() else {
            self.holding = nil
            return
        }
        proxy.scrollTo(holding.heading, anchor: .top)
    }

    /// The landing's heading is built and scrolled to: the landing is done with, here and in the
    /// store.
    private func settle(_ landing: LibraryLanding) {
        scrolledTo = landing
        landed(landing)
    }

    /// The heading of the day a file sits in — what a jump lands on (plan page 3929 decision 13:
    /// the day's heading, not its first tile). Found by the file rather than by the landing's day
    /// key, so a grid grouping in another zone than the buckets were counted in still lands on the
    /// day that holds the row the store found.
    private func headingID(holding fileID: String) -> String? {
        for month in sections {
            if let day = month.days.first(where: { $0.pictures.contains { $0.id == fileID } }) {
                return day.headingID
            }
        }
        return nil
    }

    private func scroll(inset: CGFloat) -> some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Space.tight) {
                if let error = errorText {
                    NoticeCard(text: error, tone: .error)
                        .padding(.horizontal, DesignTokens.Space.roomy)
                }
                gallery
                // The next page is on its way; this is what says so at the bottom of the scroll.
                if loadingMore {
                    ProgressView().padding(DesignTokens.Space.roomy)
                }
            }
            .padding(.vertical, DesignTokens.Space.tight)
            .coordinateSpace(.named(DayMarkers.space))
        }
        // Measured on the scroll, whose frame is real from the first layout pass, items or none.
        // It was measured on the row stack itself, which is EMPTY until a width exists — and an
        // empty lazy stack's geometry never fired on device, so the width stayed zero, zero
        // solved to no rows, and no rows kept the stack empty: a library that could never draw
        // its first page (MEMNG-206). What the rows are owed is the scroll's width inside the
        // safe area, less the gallery's own padding either side.
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(
                0,
                proxy.size.width - proxy.safeAreaInsets.leading - proxy.safeAreaInsets.trailing
                    - inset)
        } action: { width in
            contentWidth = width
        }
    }

    /// The library as day groups under month headers (MEMNG-597, plan page 3929 decision 13):
    /// per day a heading row, then its pictures as one mosaic block inset from the edges, cut into
    /// bands (`MediaLibraryPresentation.mosaicBands`).
    ///
    /// Headings and bands are siblings in the one lazy stack, so it stays lazy inside a long day as
    /// well as across days: only what is near the screen is ever built.
    private var gallery: some View {
        LazyVStack(spacing: 0) {
            ForEach(sections) { month in
                LibraryMonthHeader(label: month.label)
                    .padding(.horizontal, DesignTokens.Space.tight)
                    .padding(.bottom, DesignTokens.Space.snug)
                // One view per element, whose `.id` IS the element's identity: a lazy stack
                // resolves a scroll to a row it has not built through the ForEach's identity, so
                // a heading that was one of several views of a day's element could never be
                // scrolled to before it was on screen.
                ForEach(month.rows) { row in
                    switch row {
                    case .heading(let day):
                        LibraryDayHeading(
                            weekday: day.weekday,
                            date: day.date,
                            count: MediaLibraryPresentation.dayCount(day.key, in: dayBuckets)
                        )
                        .padding(.horizontal, DesignTokens.Space.regular)
                        .padding(.bottom, DesignTokens.Space.snug)
                        .id(row.id)
                        .modifier(marker(row.id, day: day.key, order: 2 * day.dayIndex))
                    case .band(let band, let place):
                        dayBand(band, first: place.first, last: place.last)
                            .padding(.horizontal, DesignTokens.Space.regular)
                            // 2 pt between bands, 22 pt of air before the next day's heading.
                            .padding(
                                .bottom,
                                place.last ? LibraryDayHeading.air : DesignTokens.Space.hair
                            )
                            .id(row.id)
                            .modifier(marker(row.id, day: place.day, order: 2 * place.dayIndex + 1))
                    }
                }
            }
        }
    }

    /// One band of a day block, its corners rounded where the block's are.
    private func dayBand(_ band: LibraryDayBand, first: Bool, last: Bool) -> some View {
        let radius = DesignTokens.Radius.dayBlock
        return MonthMosaicLayout(slots: band.pictures.map(\.slot), gap: DesignTokens.Space.hair) {
            ForEach(band.pictures) { placed in
                tile(placed.attachment, slot: placed.slot)
                    .onAppear {
                        guard wantsMore(placed.index) else { return }
                        Task { await loadMore() }
                    }
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: first ? radius : 0,
                bottomLeadingRadius: last ? radius : 0,
                bottomTrailingRadius: last ? radius : 0,
                topTrailingRadius: first ? radius : 0
            ))
    }

    /// What every heading and band reports while it is built: that it is (for a landing), and
    /// where on the page it starts (for the pill).
    private func marker(_ id: String, day: String, order: Int) -> BuiltMarker {
        BuiltMarker(
            id: id, day: day, order: order, onScreen: onScreen, markers: markers,
            reached: {
                guard landing != nil, landing != scrolledTo else { return }
                built += 1
            })
    }

    private var sections: [LibraryAllMonth] {
        // The library's one calendar, never the device's (`libraryTimeZone`).
        MediaLibraryPresentation.daySections(for: items)
    }

    @ViewBuilder
    private func tile(_ attachment: MemoAttachment, slot: MosaicSlot) -> some View {
        let kind = MediaLibraryPresentation.tileKind(for: attachment)
        if MediaLibraryPresentation.isOpenable(kind) {
            AttachmentThumbnail(
                attachment: attachment,
                tier: .thumb,
                // The picture fills its frame, a square or a 16:9 band, as a Months tile does; the
                // block's corners are the block's, so the tile's own are square.
                slot: AttachmentSlot(aspectRatio: slot == .wide ? 16 / 9 : 1, contentMode: .fill),
                cornerRadius: 0
            )
            .mediaTransitionSource(id: attachment.uid, in: zoom)
            .contentShape(.rect)
            .onTapGesture { open(attachment) }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(MediaLibraryPresentation.accessibilityLabel(for: kind))
            .accessibilityHint(kind == .video ? "Plays full screen" : "Opens full screen")
            .contextMenu {
                menu(attachment)
            } preview: {
                tilePreview(attachment)
            }
        } else {
            // The SAME menu, and that is the whole of this branch's change: a PDF or a voice memo
            // has a memo it hangs on and an original to keep, exactly as a photograph does. What it
            // does not have is a tap — the viewer has no page for it — and "cannot be opened" was
            // quietly being read as "cannot be acted on", which left the one kind of file you would
            // most want to save with no way to save it.
            //
            // No preview: a context-menu preview is the picture lifted off the grid, and there is
            // no picture here to lift.
            DocumentTile(
                mime: attachment.mime,
                actions: MediaTileMenu.actions(for: attachment),
                showMemo: { jump?.request($0) },
                fetch: { file, rendition in
                    Task { await fetch(file, rendition) }
                }
            )
            .contextMenu { menu(attachment) }
        }
    }

    /// What a long press offers, built once for both kinds of tile. Written into each branch
    /// separately it is one edit away from the two offering different things about one file.
    @ViewBuilder
    private func menu(_ attachment: MemoAttachment) -> some View {
        ForEach(MediaTileMenu.actions(for: attachment)) { action in
            MediaTileActionItem(
                action: action,
                showMemo: { jump?.request($0) },
                fetch: { file, rendition in
                    Task { await fetch(file, rendition) }
                }
            )
        }
    }

    /// The picture a long press lifts off the grid: the same file at the tier the viewer opens at,
    /// in its own proportions rather than the tile's square. A preview that showed the cropped
    /// thumbnail again would be a bigger version of what is already under the finger.
    private func tilePreview(_ attachment: MemoAttachment) -> some View {
        AttachmentThumbnail(
            attachment: attachment,
            tier: .mobile,
            slot: MemoPresentation.detailSlot(for: attachment)
        )
        .frame(width: MediaLibraryPresentation.previewWidth)
    }
}

/// A file that is neither a picture nor a clip.
///
/// It gets a tile rather than being hidden: the library is what the household has posted, and a
/// grid that silently drops the PDF somebody attached is a grid that lies about what is there.
/// Nothing about it is a failure, so nothing about it wears the failure glyph.
///
/// It is the ONE tile whose actions need a button. Everywhere else the long press is a shortcut —
/// a photograph opens on a tap and the viewer over it carries the same actions again — but this
/// tile has no tap and no viewer, so a context menu would be the only way to reach the memo it
/// hangs on or the file itself, and a gesture nobody is told about is not a way to reach anything.
/// So the actions are on the tile, visibly, and the long press keeps offering them as well.
/// The month a section of the library is, above its rows.
struct LibraryMonthHeader: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DesignTokens.Space.snug)
    }
}

struct DocumentTile: View {
    let mime: String
    /// What can be done with this file. Empty in a preview or a fitting test, and then no button
    /// is drawn at all — a control that opens an empty menu is worse than no control.
    var actions: [MediaTileAction] = []
    var showMemo: (String) -> Void = { _ in }
    var fetch: (MemoAttachment, AttachmentRendition) -> Void = { _, _ in }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: MediaLibraryPresentation.documentSymbol(for: mime))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(MediaLibraryPresentation.accessibilityLabel(for: .document))
            }
            // An overlay, so the button cannot change the size of the tile it sits on — the grid's
            // rows are solved from the file's own proportions and nothing drawn on top may move
            // them.
            .overlay(alignment: .topTrailing) { menuButton }
            .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
    }

    @ViewBuilder
    private var menuButton: some View {
        if !actions.isEmpty {
            Menu {
                ForEach(actions) { action in
                    MediaTileActionItem(action: action, showMemo: showMemo, fetch: fetch)
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(DesignTokens.Space.snug)
            }
            .accessibilityLabel("File actions")
        }
    }
}
