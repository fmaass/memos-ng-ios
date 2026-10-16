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
    /// The account the grid's rows were read as (MEMNG-591).
    @State private var gridAccount = GridAccount()
    /// The tags under the kind on screen (MEMNG-513): read so a tag the kind no longer holds lets
    /// the grid widen back (`loadTags`). The menu offers none since MEMNG-779 — Collections does.
    @State private var tags: LibraryTagStore?
    /// The year and day buckets the Years and Months views are drawn from (MEMNG-586).
    @State private var buckets: LibraryBucketStore?
    /// Which of Years, Months and All is on screen, and the year a Years card narrowed Months to.
    /// Shared with the scope row, whose segmented control picks it (MEMNG-604, MEMNG-690); a
    /// Library hosted with no tabs above it keeps its own, at All.
    @Environment(LibraryScopeChoice.self) private var sharedChoice: LibraryScopeChoice?
    @State private var ownChoice = LibraryScopeChoice()
    /// The dock: whether the scope row stands in the tab bar's place, and the claim select
    /// mode takes so that its toolbar is the only bottom chrome.
    @Environment(AppDock.self) private var dock: AppDock?
    /// A tag asked for from the Collections root, applied to this grid's store.
    @Environment(LibraryTagJump.self) private var tagJump: LibraryTagJump?
    /// A year asked for from the Collections root, shown in Months (MEMNG-720).
    @Environment(LibraryYearJump.self) private var yearJump: LibraryYearJump?
    @Environment(LibraryMonthJump.self) private var monthJump: LibraryMonthJump?
    /// The trips' member store, which this grid's deletes report to (MEMNG-809).
    @Environment(TripMemberStore.self) private var tripMembers: TripMemberStore?
    /// The media a tile tap opened, full screen.
    @State private var viewing: MediaViewerSelection?
    /// The download a tile's menu starts, and the sheet it ends in.
    @State private var saving = MediaSaveFlow()
    /// Select mode in All, and what it has chosen (MEMNG-588).
    @State private var selection = LibrarySelection()
    /// Select mode's Share: the chosen originals, fetched one by one into one sheet.
    @State private var sharing = MediaBatchShareFlow()
    /// The running share batch, cancelled when select mode ends so its download stops early.
    @State private var shareTask: Task<Void, Never>?
    /// Select mode's Delete: the question, and the run its yes starts (MEMNG-589).
    @State private var deleting = LibraryDeleteFlow()
    /// This Library's claim on the dock while select mode's toolbar stands in its place.
    @State private var dockClaim = UUID()
    /// What the zoom transition matches the viewer to: the tile it grew out of.
    @Namespace private var mediaZoom
    /// Which direction this device reads the library in, across launches. Read once, when the
    /// store is built, and written whenever the menu is used — the store is what the screen reads
    /// the current direction FROM, so there is only ever one answer on screen. Group by Day is
    /// read here directly, on every drawing of All: it cuts the rows, it reads none.
    private let preferences = LibraryPreferences.shared

    /// The scope row's Library icon, which gives the tabs back (`LeadingMainBar`).
    static let tabsButton = "library-show-tabs"

    /// What the app's bar draws under the Library for the dock's one `bar`: the scope row where the
    /// bar is the scope, the capsule where the tabs stand, and nothing under a claim, whose bar is
    /// the claimant's. The Library keeps the bar's room at its foot, inside its own stack, while
    /// it draws either: a change of what a bar around the stack holds moved the grid to its top
    /// (MEMNG-690), a room of one height inside it does not, and clears the grid's foot.
    static func footRow(_ bar: DockBar) -> LeadingMainBar.BarShape? {
        switch bar {
        case .scope: .scope
        case .tabs: .tabs
        case .select, .none: nil
        }
    }

    /// The one bar at the foot of the Library (`AppDock.bar(on:)`). Hosted with no dock — a test
    /// that shows the Library alone — there is no tab bar or scope toolbar to stand, and the same
    /// rule is asked of select mode's claim alone.
    private var bottomBar: DockBar {
        if let dock { return dock.bar(on: .library) }
        return DockBar.standing(
            mode: .initial, on: .library, claim: selection.isActive ? .select : nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let library {
                    content(library)
                        // A tile whose signature lapsed asks the list it came from to re-sign it.
                        .environment(\.signedURLRefresher, refresher)
                } else {
                    ProgressView()
                }
            }
            .background(Color(.systemGroupedBackground))
            // One header over All, Years and Months alike, and nothing over the grid below it:
            // the kind and the sort are chosen in its filter menu (page 3929 decision 5).
            .safeAreaBar(edge: .top) {
                if let library { header(library) }
            }
            // Select mode's toolbar, in the dock's place. It stands when the dock's one bottom
            // bar is `select` — select mode's claim (`dockClaim`) — the same value the tab bar and
            // the scope row are drawn from, so none of them is drawn beside it.
            .safeAreaBar(edge: .bottom) {
                if bottomBar == .select {
                    VStack(spacing: DesignTokens.Space.tight) {
                        if let message = deleting.message {
                            LibraryDeleteToast(text: message) { deleting.dismissMessage() }
                        }
                        LibrarySelectToolbar(
                            count: selection.count,
                            ownCount: selection.deletable(in: library?.items ?? []).own.count,
                            isSharing: sharing.isSharing,
                            isDeleting: deleteRunning,
                            share: { shareSelection() },
                            // Only the chosen pictures that are mine (MEMNG-684).
                            delete: {
                                deleting.claim(
                                    LibraryDeleteFlow.tap(selection, in: library?.items ?? []))
                            },
                            // Narrows the grid to the chosen pictures and back (MEMNG-779).
                            showSelected: { selection.toggleNarrowed() },
                            narrowed: selection.narrowed
                        )
                        .sharingFiles(sharing)
                    }
                    // On the stack around the toolbar, not on the toolbar that carries the share
                    // sheet: two presentations on one view is how one of them stops appearing.
                    .alert(
                        LibraryDeleteFlow.question(
                            count: deleting.asking?.count ?? 0, skipped: deleting.skipping),
                        isPresented: askingDelete
                    ) {
                        Button(LibraryDeleteFlow.confirmTitle, role: .destructive) {
                            confirmDelete()
                        }
                        Button("Cancel", role: .cancel) { deleting.claim(.cancelled) }
                    } message: {
                        Text(LibraryDeleteFlow.explanation)
                    }
                } else if dock != nil, Self.footRow(bottomBar) != nil {
                    // The room of the app's bar (`footRow`, MEMNG-690), which `MainTabs` keeps
                    // around every stack: the same height in both its shapes here, so the swap
                    // between them changes no inset.
                    LeadingMainBar.room
                }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            // INSIDE the stack, while the viewer's cover is outside it: two presentations declared
            // on one view is how one of them silently stops appearing, and this screen now has
            // both a cover and a sheet.
            .fetchingFile(saving)
        }
        // Outside the stack, for the reason the timeline's cover is: two presentations on one view
        // is how one of them silently stops appearing.
        // The viewer pages over the STORE, not over the rows that happened to be loaded when the
        // tile was tapped: swiping to the end of them is where the swiping used to stop, on a
        // library of over a thousand files (MEMNG-189).
        .gridViewer($viewing, refresher: refresher, zoom: mediaZoom) { _ in viewerSource }
        .tint(DesignTokens.accent)
        // Keyed on the account, as the tag and bucket lists below are: when the session becomes
        // somebody else's, this reads the incoming account's first page (MEMNG-591). Everything
        // before the read is idempotent on a second pass.
        .task(id: session.state.user?.subject) {
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
            // A choice made in the scope control abandons a jump still reading, synchronously, on
            // the store it is reading on.
            if let library {
                choice.whenChosenByHand { [weak library] in library?.abandonJump() }
            }
            // A failure that never reached the server belongs to the session's one banner, not to
            // an error card over this grid (`SessionReporting`).
            library?.reports(to: session)
            tags?.reports(to: session)
            buckets?.reports(to: session)
            reportPictureDeletes()
            // The outgoing rows go BEFORE the read is issued, whichever of this and the
            // `onChange` below heard of the new account first: a read issued first would be
            // answered for a generation the emptying has already moved past, and dropped.
            rowsBelong(to: session.state.user?.subject)
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
                mine: library?.mine,
                visibility: library?.visibility,
                subject: session.state.user?.subject
            )
        ) {
            await loadBuckets()
        }
        // A tag asked for from Collections narrows the grid, once the store exists to take it —
        // the Library may never have been opened before the request switched to it. An `onChange`
        // and an unstructured read, as the tag menu's: taking the request changes the key, and a
        // `.task` keyed on it would cancel the very read the request started.
        .onChange(of: TagJumpKey(tag: tagJump?.pending, ready: library != nil), initial: true) {
            guard let tagJump, let library, LibraryTagJumpRouting.apply(tagJump, to: library)
            else { return }
            Task { await load() }
        }
        // A year asked for from Collections: Months at that year, as a Years card's tap, once the
        // store exists to widen its tag. The scope moves inside the apply; the grid is read again
        // only when a tag was widened, unstructured for the tag request's reason.
        .onChange(of: YearJumpKey(year: yearJump?.pending, ready: library != nil), initial: true) {
            guard let yearJump, let library,
                LibraryYearJumpRouting.apply(yearJump, to: library, scope: choice)
            else { return }
            Task { await load() }
        }
        // A month asked for from Collections: Months at that month's days, the same way.
        .onChange(
            of: MonthJumpKey(month: monthJump?.pending, ready: library != nil), initial: true
        ) {
            guard let monthJump, let library,
                LibraryMonthJumpRouting.apply(monthJump, to: library, scope: choice)
            else { return }
            Task { await load() }
        }
        // The tag list is read when the Library appears, again whenever the kind changes — its
        // counts are counts under that kind — and again for whoever is signed in now.
        .task(id: TagListKey(filter: library?.filter, subject: session.state.user?.subject)) {
            await loadTags()
        }
        // The rows on this grid belong to the account they were read as. If the session becomes
        // somebody else's — or nobody's — while the tab is up, they go, the way the timeline's do.
        .onChange(of: session.state.user?.subject) { _, subject in
            selection.close()
            rowsBelong(to: subject)
            tags?.sessionIdentityChanged()
            buckets?.sessionIdentityChanged()
        }
        .onChange(of: tripMembers.map(ObjectIdentifier.init)) { reportPictureDeletes() }
        // The server is answering again, and this grid was read while it was not.
        .reloadsOnRecovery(session.reachabilityRecoveries) {
            await load()
            await loadBuckets()
        }
        // A picture that leaves the grid leaves the selection with it.
        .onChange(of: library?.items) { _, items in
            selection.prune(keeping: items ?? [])
        }
        // Select mode belongs to All: any way off it ends select mode.
        .onChange(of: choice.scope) { _, scope in
            if scope != .all { selection.close() }
        }
        // Every way select mode ends comes through here — close, leaving All, another account —
        // and each one abandons a share still fetching, so it can never offer its files later.
        .onChange(of: selection.isActive) { _, active in
            if active {
                dock?.claim(dockClaim, for: .select)
            } else {
                abandonShare()
                deleting.abandon()
                dock?.release(dockClaim)
            }
        }
        // The dock is one for every tab: a claim left behind would take it off all of them.
        .onDisappear {
            // A jump still reading when the tab is left would otherwise land its page in a grid
            // the reader no longer sees, and scroll it on their return.
            library?.abandonJump()
            selection.close()
            abandonShare()
            deleting.abandon()
            dock?.release(dockClaim)
        }
    }

    /// What the full-screen viewer reads. `.fixed` only when there is no store yet, which is a
    /// state no tap can be made in — the grid it would be tapped on does not exist either.
    /// Who re-signs a lapsed picture of the grid or the viewer: a walk of the pages the library
    /// holds. The covers under Years and Months are re-signed by their own store, set on the
    /// subtree that draws them (`bucketContent`).
    private var refresher: LibraryURLRefresher? {
        guard let library else { return nil }
        return LibraryURLRefresher(library: library, session: IssuingSession(session))
    }

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
            mine: library.mine,
            visibility: library.visibility,
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
                .feedsDock(dock)
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
                .feedsDock(dock)
            }
        }
        // Nearer than the grid's refresher, so it is the one a cover's tile reads.
        .environment(
            \.signedURLRefresher,
            BucketURLRefresher(buckets: store, session: IssuingSession(session))
        )
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
            // While "Show Selected" is on, only the chosen pictures, in the grid's order — the
            // months and days they fall in keep their headings (MEMNG-779).
            items: selection.visible(in: library.items),
            errorText: library.lastError,
            loadingMore: library.isLoadingMore,
            zoom: mediaZoom,
            // An index into the narrowed list is no position in the store's: no paging from it.
            wantsMore: { !selection.narrowed && library.shouldLoadMore(after: $0) },
            open: { open($0) },
            fetch: { file, rendition in await fetch(file, rendition) },
            loadMore: { await loadMore() },
            landing: library.landing,
            landed: { library.consumeLanding($0) },
            // Asked where it is acted on, never remembered from the last drawing: the store can
            // replace the list between a drawing and a geometry callback already on its way.
            listGeneration: { library.listGeneration },
            selection: selection,
            toggle: { selection.toggle($0) },
            dayBuckets: buckets.flatMap { store in
                bucketsShown(
                    for: .all,
                    filter: library.filter,
                    tag: library.tag,
                    mine: library.mine,
                    visibility: library.visibility,
                    timeZoneIdentifier: store.timeZoneIdentifier,
                    buckets: store.buckets,
                    answering: store.loadedRequest
                )
            },
            showMonth: { choice.showMonth($0) },
            // Select mode and Show Selected draw the same tiles in the same cut (MEMNG-818).
            grouping: preferences.allGrouping
        )
        // The Library's scroll is what swaps the tab bar for the scope toolbar (MEMNG-679), on
        // each of its three scroll views.
        .feedsDock(dock)
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

    /// The title, the line naming what the grid holds, and the filter menu that changes it.
    private func header(_ library: MediaLibraryStore) -> some View {
        LibraryHeader(
            subtitle: MediaLibraryPresentation.subtitle(
                filter: library.filter,
                order: library.order,
                tag: library.tag
            ),
            select: choice.scope == .all ? { selection.begin() } : nil,
            selecting: selection.isActive,
            close: { selection.close() }
        ) {
            LibraryFilterMenuContent(
                filter: filterBinding(library),
                mine: mineBinding(library),
                visibility: visibilityBinding(library),
                order: sortBinding(library),
                groupByDay: groupByDayBinding,
                tileLayout: tileLayoutBinding
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

    /// "Captured by me" (MEMNG-787): a new list, read from its first page as a kind is; the buckets
    /// follow through their task key, which names it. Not persisted, as the kind is not.
    private func mineBinding(_ library: MediaLibraryStore) -> Binding<Bool> {
        Binding(
            get: { library.mine },
            set: { chosen in
                guard chosen != library.mine else { return }
                library.setMine(chosen)
                Task { await load() }
            }
        )
    }

    /// Visibility (MEMNG-787), as "Captured by me".
    private func visibilityBinding(_ library: MediaLibraryStore) -> Binding<MediaVisibilityFilter> {
        Binding(
            get: { library.visibility },
            set: { chosen in
                guard chosen != library.visibility else { return }
                library.setVisibility(chosen)
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

    /// View Options → Group by Day (MEMNG-818): the device's choice and nothing else. The grid is
    /// re-cut from the rows the store already holds — no reload, the cursor where it was.
    private var groupByDayBinding: Binding<Bool> {
        Binding(
            get: { preferences.groupByDay },
            set: { preferences.select(groupByDay: $0) }
        )
    }

    /// View Options → Mixed Sizes / Square Grid (MEMNG-821): written here, read by every grid
    /// itself, so this screen passes nothing on. No reload either.
    private var tileLayoutBinding: Binding<LibraryTileLayout> {
        Binding(
            get: { preferences.tileLayout },
            set: { preferences.select(tileLayout: $0) }
        )
    }

    /// Opens the viewer over the WHOLE library, at the tile that was tapped — and, because the
    /// viewer reads the store rather than a snapshot of it, a swipe carries on past the rows that
    /// were loaded at the moment of the tap.
    private func open(_ attachment: MemoAttachment) {
        guard let library else { return }
        viewing = MediaGridHosting.viewing(attachment, in: library.items)
    }

    /// Fetches the named file of a tile's attachment and offers it to the share sheet. The
    /// credential the original tier needs is the session's, and it stays there (see
    /// `OriginalMedia`).
    private func fetch(_ attachment: MemoAttachment, _ rendition: AttachmentRendition) async {
        await MediaGridHosting.fetch(attachment, rendition, saving: saving, session: session)
    }

    /// Select mode's Share: the chosen rows, in the order they were chosen, each fetched as its
    /// ORIGINAL through the session's download lane, the batch fenced by the session generation it
    /// started under (`MediaBatchShareFlow`).
    private func shareSelection() {
        guard let library else { return }
        let rows = selection.rows(in: library.items)
        shareTask = Task {
            _ = await sharing.share(
                rows,
                generation: { [session] in session.activeHandle?.generation },
                download: { [session] file, rendition in
                    try await session.download(file, rendition)
                }
            )
        }
    }

    /// Select mode ended: the batch stops being the live one (`MediaBatchShareFlow.abandon`) and
    /// its task is cancelled, so the download it is waiting on ends early.
    private func abandonShare() {
        sharing.abandon()
        shareTask?.cancel()
        shareTask = nil
    }

    /// A delete run is out — this flow's, or one an abandoned select mode left running, which the
    /// store would refuse a second run beside anyway.
    private var deleteRunning: Bool {
        deleting.isDeleting || library?.isDeleting == true
    }

    private var askingDelete: Binding<Bool> {
        Binding(
            get: { deleting.asking != nil },
            set: { if !$0 { deleting.claim(.cancelled) } }
        )
    }

    /// The alert's yes. The session handle is taken HERE, at the answer, and the whole run goes out
    /// on it (`MediaLibraryStore.delete`). Claimed synchronously, before any task, for the reason
    /// `MemoDetailView.sendPictureDelete` gives.
    ///
    /// The run's task is deliberately not kept for cancelling: a DELETE already sent cannot be
    /// recalled, so select mode ending lets the run finish and only stops listening to it
    /// (`LibraryDeleteFlow.abandon`). The grid drops what went either way — the store applies it —
    /// and the day counts are read again, so Months and Years do not count pictures that are gone.
    private func confirmDelete() {
        guard let library, let handle = session.activeHandle else {
            deleting.claim(.cancelled)
            return
        }
        guard deleting.claim(.confirmed) else { return }
        Task {
            let outcome = await deleting.perform { uids in
                await library.delete(uids, using: handle)
            }
            guard let outcome, !outcome.deleted.isEmpty, !outcome.stoppedForSessionChange else {
                return
            }
            await loadBuckets(refreshing: true)
        }
    }

    /// A picture this grid deletes retires the New trip sheet's counts and spans, and reads again
    /// the trips that held it (MEMNG-809): its deletes report to the member store built beside
    /// the tabs. Wired whenever either store arrives, whichever comes first.
    private func reportPictureDeletes() {
        let baseURL: @MainActor () -> URL? = { [session] in session.serverBaseURL }
        library?.onPicturesDeleted = tripMembers?.picturesDeletedHook(baseURL: baseURL)
    }

    /// Empties the grid when the account its rows were read as is no longer `subject` — once per
    /// change of account, whether the read keyed on the account or the `onChange` gets here
    /// first, so the generation the incoming read is issued under is never moved again after it.
    private func rowsBelong(to subject: String?) {
        guard let library, gridAccount.claim(subject) else { return }
        library.sessionIdentityChanged()
    }

    /// What the tag request's read is keyed on: the request, and whether there is a store yet.
    private struct TagJumpKey: Equatable {
        let tag: String?
        let ready: Bool
    }

    private struct YearJumpKey: Equatable {
        let year: String?
        let ready: Bool
    }

    private struct MonthJumpKey: Equatable {
        let month: String?
        let ready: Bool
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
                mine: library.mine,
                visibility: library.visibility,
                using: handle,
                baseURL: baseURL
            )
        } else {
            await buckets.load(
                size: size,
                filter: library.filter,
                tag: library.tag,
                mine: library.mine,
                visibility: library.visibility,
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
    let mine: Bool?
    let visibility: MediaVisibilityFilter?
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

/// The account the Library grid's rows were read as, kept out of SwiftUI's observation: the two
/// places that hear of a new account in one update read it straight after each other.
final class GridAccount {
    /// Nil until the grid's first read records an account; `.some(nil)` is nobody signed in.
    private var subject: String??

    /// Records `new` as the account the rows are read as. True when that moves it off another
    /// account — the one moment the rows must go. The first record moves nothing.
    func claim(_ new: String?) -> Bool {
        defer { subject = .some(new) }
        guard let recorded = subject else { return false }
        return recorded != new
    }
}

/// The rows a grid's lazy stack has built now, kept out of SwiftUI's observation (`LibraryGrid`).
final class RowsOnScreen {
    var rows: Set<String> = []
}

/// What a `LibraryGrid` is drawn in: its grouping and the device's tile layout, re-cut together.
struct LibraryGridCut: Equatable {
    let grouping: LibraryGridGrouping
    let tiles: LibraryTileLayout
}

/// The file a grid keeps at the line until the reader's hand moves: a landing's, held by its day's
/// heading in a grouped grid and by its band in a flat one, or the picture a re-cut kept, by its
/// band. `listGeneration` is the list it was taken in.
struct HeldFile: Equatable {
    let file: String
    let byHeading: Bool
    let listGeneration: Int
}

/// How a `LibraryGrid` cuts its list (MEMNG-740).
enum LibraryGridGrouping {
    /// The Library's All: a header per month, a heading per day, a block per day.
    case byDay
    /// A trip's: the whole list as one block, with no header and no heading
    /// (`MediaLibraryPresentation.flatRows`).
    case flat
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
    /// Select mode (MEMNG-588): while it is on, a tap chooses rather than opens.
    var selection = LibrarySelection()
    /// A tap on a loaded picture in select mode, mine or another member's (MEMNG-684).
    var toggle: (LibraryRow) -> Void = { _ in }
    /// The day buckets a heading's count is read from, or nil while none answer this list
    /// (`MediaLibraryPresentation.dayCount`).
    var dayBuckets: [LibraryBucket]?
    /// The date pill's tap: Months at this `YYYY-MM` month (plan page 3929 decision 13).
    var showMonth: (String) -> Void = { _ in }
    /// What the host draws at the top of the scroll, above the first month — a trip's hero
    /// (MEMNG-714). The Library has none: its header stands over the grid, not in it.
    var above: AnyView?
    /// What the host draws at the foot of the scroll, under the last picture — a trip's cap note.
    var below: AnyView?
    /// Days with their headings, or one block with none — a trip's (MEMNG-740). The same tiles,
    /// zoom, tap and long press either way: only the rows the stack is cut into differ.
    var grouping = LibraryGridGrouping.byDay
    /// The device's View Options, of which the grid reads the tile layout itself (MEMNG-821): All
    /// and the trip and collection screens follow it with nothing passed on. A test hands in its
    /// own, over a scratch suite.
    var preferences = LibraryPreferences.shared
    /// The way to a memo from a tab that cannot open one. Optional: a preview or a test host has
    /// no router, and a missing environment value must be a missing action, not a crash.
    @Environment(MemoJump.self) private var jump: MemoJump?
    /// Told before each scroll to a landing, so the move it makes counts as a scroll (MEMNG-679).
    @Environment(AppDock.self) private var dock: AppDock?
    /// How wide the rows are solved for — the scroll's own width, less the padding. Measured
    /// rather than assumed, so a rotation or a split view re-packs the library rather than
    /// running it off the edge.
    @State private var contentWidth: CGFloat = 0
    /// The landing this grid has brought its scroll to: a width measured again afterwards must not
    /// bring the reader back to it.
    @State private var scrolledTo: LibraryLanding?
    /// The heading a landing brought to the line — or, in a flat grid and after a re-cut, the band
    /// holding the file — held there until the reader's own hand moves the scroll. Each time the
    /// lazy stack measures rows it has not built yet, the scroll is put back where its estimate
    /// says — for a heading on the first screen, the top of the page — so reaching the line once
    /// does not keep it there. It belongs to the list it landed in (`listGeneration`): a next page
    /// keeps it, any other list lets it go. What is held is the FILE, its row found again at each
    /// hold: a next page keeps the list but may re-cut the file's day, and a band is named by its
    /// first file, so the band a file sat in before the page may no longer exist after it.
    @State private var holding: HeldFile?
    /// The cut the stack is drawn in now: the grouping and the tile layout as they were when the
    /// grid last re-cut itself. Kept apart from both so a change of either is answered while the
    /// old cut is still drawn and measured — the one moment the picture at the top of the screen
    /// can be read (MEMNG-818, MEMNG-821).
    @State private var drawnCut: LibraryGridCut?
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
    /// A "Show Selected" press still bringing the chosen pictures into view (MEMNG-819): the first
    /// chosen file in the grid's order, and which way the press went. A file, not a band: a band
    /// is named by its first file, so the band holding it is another one on each side of the press.
    @State private var revealing: (fileID: String, narrowed: Bool)?

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
                // Group by Day re-cuts the rows in place: the store's list and cursor stay, and
                // the picture at the top of the screen is the one the reader is shown after it.
                .onChange(of: wantedCut, initial: true) { _, new in recut(to: new, proxy) }
                // Narrowing leaves a band or two at the top of a page still scrolled to where the
                // pictures were chosen, which then shows nothing; widening puts back everything
                // above them. Either way the chosen pictures are brought into view (MEMNG-819).
                .onChange(of: selection.narrowed) { _, narrowed in
                    revealing = items.first { selection.contains($0.id) }.map { ($0.id, narrowed) }
                    // A landing's held heading would pull the page back over them.
                    holding = nil
                    // A band the wide grid had built may keep its identity in the narrowed one,
                    // so whether it is built does not say the page can reach it: the gallery's top
                    // first, every time, where the narrowed grid's first band is.
                    if narrowed { proxy.scrollTo(Self.galleryID, anchor: .top) }
                    reveal(proxy)
                }
                // And again each time the rows are laid out anew: a scroll to a row the lazy stack
                // has not built goes where its estimate puts it, which moves as rows are measured.
                // No delay stands in for this: the layout, and the rows built, say when to ask.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height
                } action: { _, laid in
                    hold(proxy)
                    reveal(proxy)
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
                    reveal(proxy)
                }
                // The reader's own scroll lets go of the landing's heading.
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        holding = nil
                        revealing = nil
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

    /// Scrolls to the landing's day heading — in a flat grid, which has none, to the band holding
    /// the file the store found — again as often as asked until the lazy stack has built it: each
    /// ask lands nearer, and only a built row's place is exact rather than estimated.
    private func bring(_ proxy: ScrollViewProxy) {
        guard let landing, landing != scrolledTo else { return }
        let target: String? =
            switch cut.grouping {
            case .byDay: headingID(holding: landing.rowID)
            case .flat: tileID(holding: landing.rowID, in: cut)
            }
        guard let heading = target else { return }
        // A new landing takes over from the one held before it, and from a press's reveal.
        holding = nil
        revealing = nil
        // The app's own jump, not the layout's: the dock counts the move it makes. `hold` below
        // does not tell it, because it only answers a layout that moved the scroll.
        dock?.askedToJump()
        proxy.scrollTo(heading, anchor: .top)
        // Built AND at the line — or the scroll at its end, when too little follows the heading
        // for it to rise that far. A heading built on the first screen is built before the scroll
        // can move, so being built alone does not say the scroll went there.
        if onScreen.rows.contains(heading), markers.reached(heading) {
            settle(landing)
            holding = HeldFile(
                file: landing.rowID, byHeading: cut.grouping == .byDay,
                listGeneration: listGeneration())
        }
    }

    /// Brings the held heading back to the line whenever a layout has moved the scroll off it.
    private func hold(_ proxy: ScrollViewProxy) {
        guard let holding else { return }
        // Found in the rows drawn now, not remembered: see `holding`. A file no longer in them has
        // nothing left to hold.
        guard let row = heldRow(holding) else {
            self.holding = nil
            return
        }
        guard !markers.reached(row) else { return }
        // Judged against the list it was taken in, asked of the store here, with nothing between
        // the question and the scroll: after a filter, tag or order change the store has dropped
        // the landing, and the same day in the new list is not the reader's to be brought back to.
        guard holding.listGeneration == listGeneration() else {
            self.holding = nil
            return
        }
        proxy.scrollTo(row, anchor: .top)
    }

    /// The row a held file is kept at in the cut drawn now: its day's heading, or its band.
    private func heldRow(_ held: HeldFile) -> String? {
        held.byHeading ? headingID(holding: held.file) : tileID(holding: held.file, in: cut)
    }

    /// Re-cuts the stack into `new` and keeps the reader's picture in view (MEMNG-818). The first
    /// file reaching below the line is read from the markers of the cut still drawn, then the band
    /// holding that file in the new cut is scrolled to the line and held there like a landing's
    /// heading, so the lazy stack re-measuring the rows it builds cannot carry it off. At the top
    /// of the page the top stays the top: there is nothing above to keep.
    private func recut(to new: LibraryGridCut, _ proxy: ScrollViewProxy) {
        guard let drawn = drawnCut else {
            drawnCut = new
            return
        }
        guard drawn != new else { return }
        // The re-cut takes over from whatever was held: the reader's picture is the one kept now.
        holding = nil
        let bands = Set(rows(in: drawn).compactMap(Self.bandID))
        let anchor =
            markers.line.y > 1 ? markers.first(reaching: markers.line.y, among: bands) : nil
        drawnCut = new
        guard let anchor, let row = tileID(holding: anchor, in: new) else { return }
        holding = HeldFile(file: anchor, byHeading: false, listGeneration: listGeneration())
        // The app's own move, as a landing's is: the dock counts it as no reader's scroll.
        dock?.askedToJump()
        proxy.scrollTo(row, anchor: .top)
    }

    /// The cut asked for now: the host's grouping and the device's tile layout.
    private var wantedCut: LibraryGridCut {
        LibraryGridCut(grouping: grouping, tiles: preferences.tileLayout)
    }

    /// The cut the stack is drawn in, before its first re-cut the one it was built with.
    private var cut: LibraryGridCut { drawnCut ?? wantedCut }

    /// The lazy stack's rows in a cut, its tile layout included: a band's files depend on it.
    private func rows(in cut: LibraryGridCut) -> [LibraryAllRow] {
        switch cut.grouping {
        case .byDay:
            MediaLibraryPresentation.daySections(for: items, tiles: cut.tiles).flatMap(\.rows)
        case .flat: MediaLibraryPresentation.flatRows(for: items, tiles: cut.tiles)
        }
    }

    private static func bandID(_ row: LibraryAllRow) -> String? {
        guard case .band(let band, _) = row else { return nil }
        return band.id
    }

    /// The band a file sits in, in a cut — what a flat landing and a re-cut scroll to. A band is
    /// named by its FIRST file, so the file is looked for among each band's pictures: in the other
    /// cut it may well be a band's second or third.
    private func tileID(holding fileID: String, in cut: LibraryGridCut) -> String? {
        for row in rows(in: cut) {
            if case .band(let band, _) = row, band.pictures.contains(where: { $0.id == fileID }) {
                return band.id
            }
        }
        return nil
    }

    /// Brings the band holding the press's file to the top, again as the lazy stack measures, until
    /// it is built and at the line — or the page can scroll no further, or the reader scrolls.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let revealing else { return }
        // Another press, or the file gone from the list: this one is over.
        guard revealing.narrowed == selection.narrowed,
            let band = bandID(holding: revealing.fileID)
        else {
            self.revealing = nil
            return
        }
        // The gallery is ONE child of the page's lazy stack: narrowed, it is a band or two above
        // the screen, which the page has not built, so no row inside it can be scrolled to yet.
        // Its own top first — the narrowed grid's first band holds the file — then the band.
        if revealing.narrowed, !onScreen.rows.contains(band) {
            proxy.scrollTo(Self.galleryID, anchor: .top)
            return
        }
        proxy.scrollTo(band, anchor: .top)
        if onScreen.rows.contains(band), markers.reached(band) {
            self.revealing = nil
        }
    }

    /// The band of the grid as drawn now that holds `fileID`: in a flat grid as in a grid by day.
    /// Read from the cut the stack is drawn in, its tile layout included — under Square Grid the
    /// bands are rows of three, so the mixed layout's bands name rows that are not drawn.
    private func bandID(holding fileID: String) -> String? {
        tileID(holding: fileID, in: cut)
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
        // A flat grid has no heading to land on.
        guard cut.grouping == .byDay else { return nil }
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
                if let above {
                    above
                }
                if let error = errorText {
                    NoticeCard(text: error, tone: .error)
                        .padding(.horizontal, DesignTokens.Space.roomy)
                }
                gallery
                    .id(Self.galleryID)
                // The next page is on its way; this is what says so at the bottom of the scroll.
                if loadingMore {
                    ProgressView().padding(DesignTokens.Space.roomy)
                }
                if let below {
                    below
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
    /// well as across days: only what is near the screen is ever built. A flat grid is the same
    /// bands with no header and no heading among them (MEMNG-740).
    private var gallery: some View {
        LazyVStack(spacing: 0) {
            switch cut.grouping {
            case .byDay:
                ForEach(sections) { month in
                    // The header title's 16 pt edge, which the day heading shares (MEMNG-756).
                    LibraryMonthHeader(label: month.label)
                        .padding(.horizontal, DesignTokens.Space.roomy)
                        .padding(.bottom, DesignTokens.Space.snug)
                    // One view per element, whose `.id` IS the element's identity: a lazy stack
                    // resolves a scroll to a row it has not built through the ForEach's identity,
                    // so a heading that was one of several views of a day's element could never
                    // be scrolled to before it was on screen.
                    ForEach(month.rows) { row in
                        element(row)
                    }
                }
            case .flat:
                ForEach(MediaLibraryPresentation.flatRows(for: items, tiles: cut.tiles)) { row in
                    element(row)
                }
            }
        }
    }

    /// One element of the lazy stack: a day's heading, or one band of a block.
    @ViewBuilder
    private func element(_ row: LibraryAllRow) -> some View {
        switch row {
        case .heading(let day):
            LibraryDayHeading(
                weekday: day.weekday,
                date: day.date,
                count: MediaLibraryPresentation.dayCount(day.key, in: dayBuckets)
            )
            .padding(.horizontal, DesignTokens.Space.roomy)
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

    /// One band of a day block, its corners rounded where the block's are.
    private func dayBand(_ band: LibraryDayBand, first: Bool, last: Bool) -> some View {
        let radius = DesignTokens.Radius.dayBlock
        return MonthMosaicLayout(slots: band.pictures.map(\.slot), gap: DesignTokens.Space.hair) {
            ForEach(band.pictures) { placed in
                tile(
                    placed.attachment,
                    slot: placed.slot,
                    row: LibrarySelectionPresentation.row(
                        at: placed.index, uid: placed.id, in: items)
                )
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
        MediaLibraryPresentation.daySections(for: items, tiles: cut.tiles)
    }

    /// The gallery's identity in the page, for a scroll to reach it while the page has not built it.
    static let galleryID = "library-gallery"

    /// What a test finds a loaded tile by: the file it shows, which its label does not say.
    static func tileIdentifier(_ uid: String) -> String { "library-tile:\(uid)" }

    @ViewBuilder
    private func tile(
        _ attachment: MemoAttachment, slot: MosaicSlot, row: LibraryRow?
    ) -> some View {
        let kind = MediaLibraryPresentation.tileKind(for: attachment)
        let state = LibrarySelectionPresentation.tile(for: row, in: selection)
        let hint = LibrarySelectionPresentation.tileHint(for: kind, selecting: state != .browsing)
        if MediaLibraryPresentation.isOpenable(kind) {
            // A button, not a bare tap gesture (MEMNG-684): the one action a finger's tap and an
            // accessibility activation both run — open while browsing, choose in select mode — and
            // the control the system arbitrates against the context menu's long press.
            Button {
                tapped(attachment, row: row)
            } label: {
                AttachmentThumbnail(
                    attachment: attachment,
                    tier: .thumb,
                    // The picture fills its frame, a square or a 16:9 band, as a Months tile does;
                    // the block's corners are the block's, so the tile's own are square.
                    slot: AttachmentSlot(
                        aspectRatio: slot == .wide ? 16 / 9 : 1, contentMode: .fill),
                    cornerRadius: 0
                )
                .mediaTransitionSource(id: attachment.uid, in: zoom)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MediaLibraryPresentation.accessibilityLabel(for: kind))
            .accessibilityHint(hint)
            .accessibilityIdentifier(Self.tileIdentifier(attachment.uid))
            .contextMenu {
                menu(attachment)
            } preview: {
                tilePreview(attachment)
            }
            .modifier(SelectableTile(state: state))
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
                // In select mode a tap chooses, so the tile's own button is not drawn over it.
                actions: state == .browsing ? MediaTileMenu.actions(for: attachment) : [],
                showMemo: { jump?.request($0) },
                fetch: { file, rendition in
                    Task { await fetch(file, rendition) }
                }
            )
            .contentShape(.rect)
            .onTapGesture {
                if state != .browsing { tapped(attachment, row: row) }
            }
            .contextMenu { menu(attachment) }
            .modifier(SelectableTile(state: state))
        }
    }

    /// A tile's tap: the viewer while browsing, the selection in select mode — any loaded tile,
    /// mine or another member's (MEMNG-684). A tile with no row never gets here in select mode
    /// (`SelectableTile` makes it inert), and there is no row to choose besides.
    private func tapped(_ attachment: MemoAttachment, row: LibraryRow?) {
        guard selection.isActive else {
            open(attachment)
            return
        }
        if let row { toggle(row) }
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
