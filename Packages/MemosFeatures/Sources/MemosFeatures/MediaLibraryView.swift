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
    /// Which of Years, Months and All is on screen. All is the grid this screen always drew.
    @State private var scope: LibraryScope = .all
    /// The year a Years card narrowed the Months view to, or nil for every year.
    @State private var year: String?
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
            .navigationTitle("Library")
            .navigationSubtitle(MediaLibraryPresentation.subtitle(for: library?.tag))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let library {
                    ToolbarItem(placement: .topBarLeading) { scopePicker }
                    ToolbarItem(placement: .topBarTrailing) { optionsMenu(library) }
                }
            }
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
                scope: scope,
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

    @ViewBuilder
    private func content(_ library: MediaLibraryStore) -> some View {
        switch scope {
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

    /// Years and Months: the buckets under the same filter bar, the view on screen drawn only from
    /// a list read for it (`bucketsShown`).
    @ViewBuilder
    private func bucketContent(
        _ library: MediaLibraryStore,
        _ store: LibraryBucketStore
    ) -> some View {
        // Nil while the store's list answers some other selection — a read still on its way, or
        // one that failed and left the previous kind's list standing.
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
            } else {
                LibraryMonthsMosaic(
                    months: mosaicMonths(year.map { dayBuckets(shown, inYear: $0) } ?? shown),
                    year: year,
                    errorText: store.lastError,
                    clearYear: { year = nil },
                    showDay: { showDay($0) }
                )
            }
        }
        .safeAreaInset(edge: .top) { filterBar(library) }
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
        .refreshable { await loadBuckets() }
    }

    /// The segment that picks Years, Months or All. Choosing one by hand widens Months back to
    /// every year: the narrowing belongs to the Years card that asked for it.
    private var scopePicker: some View {
        let selection = Binding(
            get: { scope },
            set: { chosen in
                year = nil
                scope = chosen
            }
        )
        return Picker("Library view", selection: selection) {
            ForEach(LibraryScope.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// A Years card opens that year's days in the Months view, narrowed on the device from the one
    /// list of day buckets, the way the web does.
    private func chooseYear(_ key: String) {
        year = key
        scope = .months
    }

    /// A day tile's tap. MEMNG-587 makes this the jump into the All grid at that day; until then
    /// a day is looked at, not opened.
    private func showDay(_ day: LibraryBucket) {}

    @ViewBuilder
    private func grid(_ library: MediaLibraryStore) -> some View {
        LibraryGrid(
            items: library.items,
            // The device's zone, which is the one the month buckets are asked for in, so a header
            // and the bucket it stands for name the same month.
            timeZone: TimeZone.current.identifier,
            errorText: library.lastError,
            loadingMore: library.isLoadingMore,
            zoom: mediaZoom,
            wantsMore: { library.shouldLoadMore(after: $0) },
            open: { open($0) },
            fetch: { file, rendition in await fetch(file, rendition) },
            loadMore: { await loadMore() }
        )
        // Pinned above the scroll rather than inside it: the filter is how you change what the
        // grid IS, and one that scrolls away is one you have to scroll back up to reach.
        .safeAreaInset(edge: .top) { filterBar(library) }
        .overlay {
            if let empty = MediaLibraryPresentation.emptyOverlay(
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
        .refreshable { await load() }
    }

    /// The three tabs of the filter, as a segmented control — the iOS shape of the SPA's
    /// `SelectButton`. Changing it resets the paging (`setFilter`) and reads the first page of the
    /// tab that was chosen.
    private func filterBar(_ library: MediaLibraryStore) -> some View {
        let selection = Binding(
            get: { library.filter },
            set: { chosen in
                library.setFilter(chosen)
                Task { await load() }
            }
        )
        return Picker("Filter media type", selection: selection) {
            ForEach(MediaLibraryFilter.allCases) { filter in
                Text(MediaLibraryPresentation.label(for: filter)).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Filter media type")
        .padding(.horizontal, DesignTokens.Space.roomy)
        .padding(.vertical, DesignTokens.Space.snug)
        .background(.bar)
    }

    /// Which end of the library the grid starts at — a menu of checkmark rows, which is the shape
    /// Photos gives a single sort key on an album. A segmented control beside the filter would put
    /// two different questions on one bar and spend the width of the screen on the one that is
    /// answered once a year (MEMNG-190).
    /// The Library's options: the sort, and the tag the grid is narrowed to. Each section is an
    /// inline Picker, which is what draws the checkmark on the chosen row — one selection each, so
    /// choosing a row un-chooses the other.
    private func optionsMenu(_ library: MediaLibraryStore) -> some View {
        Menu {
            Picker("Sort", selection: sortBinding(library)) {
                ForEach(MediaLibraryOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
            Picker("Tags", selection: tagBinding(library)) {
                ForEach(tagRows(library)) { row in
                    Text(row.label).tag(row.selection)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Options")
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
    /// narrowed to. All is drawn from the list and reads none.
    private func loadBuckets() async {
        guard let library, let buckets, let size = scope.bucketSize,
            let handle = session.activeHandle, let baseURL = session.serverBaseURL
        else { return }
        await buckets.load(
            size: size,
            filter: library.filter,
            tag: library.tag,
            using: handle,
            baseURL: baseURL
        )
    }

    private func loadMore() async {
        guard let library, let handle = session.activeHandle,
            let baseURL = session.serverBaseURL
        else { return }
        await library.loadMore(using: handle, baseURL: baseURL)
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

struct LibraryGrid: View {
    let items: [LibraryRow]
    /// The zone the month sections are calendar months of.
    let timeZone: String
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
    /// The way to a memo from a tab that cannot open one. Optional: a preview or a test host has
    /// no router, and a missing environment value must be a missing action, not a crash.
    @Environment(MemoJump.self) private var jump: MemoJump?
    /// How wide the rows are solved for — the scroll's own width, less the padding. Measured
    /// rather than assumed, so a rotation or a split view re-packs the library rather than
    /// running it off the edge.
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        // Hoisted because the measuring closure below is `Sendable` and may run off the main
        // actor, where the design tokens are not reachable.
        let inset = 2 * DesignTokens.Space.tight
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

    /// The library as justified rows: every file in its own proportions, rows that fill the width.
    ///
    /// A `LazyVStack` of rows rather than one layout over every tile, and that is the reason the
    /// solving happens in `MediaLibraryPresentation` instead of inside a `Layout`: a `Layout`
    /// places all of its subviews, and this grid is a thousand files long. Solved into rows first,
    /// the stack stays lazy — only the rows near the screen are ever built — while each row is a
    /// plain `HStack` of boxes the solver has already sized.
    ///
    /// Each month is headed by its name and solved on its own (MEMNG-585), the headers and rows
    /// siblings in the one lazy stack so it stays lazy across months as well as within them.
    private var gallery: some View {
        LazyVStack(spacing: DesignTokens.Space.tight) {
            ForEach(sections) { section in
                LibraryMonthHeader(label: section.label)
                ForEach(section.rows) { row in
                    HStack(spacing: DesignTokens.Space.tight) {
                        ForEach(row.tiles) { placed in
                            tile(placed.attachment)
                                .frame(width: placed.width, height: placed.height)
                                .onAppear {
                                    guard wantsMore(placed.index) else { return }
                                    Task { await loadMore() }
                                }
                        }
                        // Rows are packed from the left; the trailing one is short by design and
                        // must not be stretched across the width (`JustifiedGallery`).
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, DesignTokens.Space.tight)
    }

    private var sections: [LibraryGallerySection] {
        MediaLibraryPresentation.sections(
            for: items,
            width: Double(contentWidth),
            gap: Double(DesignTokens.Space.tight),
            timeZone: timeZone
        )
    }

    @ViewBuilder
    private func tile(_ attachment: MemoAttachment) -> some View {
        let kind = MediaLibraryPresentation.tileKind(for: attachment)
        if MediaLibraryPresentation.isOpenable(kind) {
            AttachmentThumbnail(
                attachment: attachment,
                tier: .thumb,
                // The box IS the picture's own shape now, so nothing is cropped into it — the
                // same slot the memo card's justified rows use.
                slot: MemoPresentation.justifiedSlot(for: attachment)
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
