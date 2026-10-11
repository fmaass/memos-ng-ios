import MemosCore
import SwiftUI

/// What the Collections root pushes for a trip card: the trip, known by its id.
struct TripRoute: Hashable {
    let id: UUID
    /// The trip as it was when its card was opened. Its screen draws this once the trip has left
    /// the store, while the stack lets the screen go: a destination that drew nothing for a trip
    /// that is gone would take the screen's own way off the stack with it.
    let opened: CollectionRecord

    init(_ record: CollectionRecord) {
        id = record.id
        opened = record
    }

    static func == (lhs: TripRoute, rhs: TripRoute) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A trip stands inside the Collections tab (MEMNG-715): the main bar stays under it, with its
/// room at the screen's foot, as under a memo pushed on the Timeline.
extension TripRoute: @MainActor StackRoute {
    static let chrome = ScreenChrome.withinTab
}

/// A trip, in Photos mode (MEMNG-714): its hero — the cover, the title, the span and the count —
/// the `Photos | Journal | Map` chips, and every one of its pictures and videos oldest first, as
/// one flat block: the Library's All without its days (MEMNG-740, `LibraryGridGrouping.flat`).
///
/// **The grid is the Library's.** `LibraryGrid` is hosted over the trip's DRAINED members
/// (`TripMembershipStore.members(for:)`), which are already the record's pictures minus its
/// exclusions, so an excluded picture is absent from the grid, the hero, the count and the viewer
/// alike. No second `MediaLibraryStore` is built: the drain reads the whole trip before anything is
/// shown, so the grid never asks for a next page and its `loadMore` is a no-op. A drain that
/// stopped at the cap says so under the last picture.
///
/// **What the host owes the grid** comes from `MediaGridHosting`, the helpers extracted from
/// `MediaLibraryView`: the viewer a tap opens (`.fixed` over the same filtered members, never
/// `.library`, whose store would bring an excluded picture back) and the session's download lane
/// for a tile's menu. Re-signing a lapsed picture reads the trip again (`TripURLRefresher`).
/// Reporting and the identity reset are the session's, not this screen's: the membership store
/// reports to the session from the moment it is built (`MainTabView`) and is moved with the
/// identity beside the timeline (`CollectionsSession`), so a trip read as somebody else drops.
///
/// **The drain refreshes on appear**, and again when the account, the trip's tag or its span
/// changes; a drain of the same trip already on the wire — the root's — is joined, never repeated.
///
/// **Manage.** Rename, Trip Dates, Pin or Unpin, Move Up, Move Down and Delete Trip, through
/// `TripManage`; Trip Dates opens `TripSpanSheet`, whose saved span reads the trip again.
/// Pin or Unpin is one item, named by whether this trip is the scope's active pin now
/// (`CollectionStore.activePin(now:)`), so a pin that has expired offers Pin again. A trip that
/// is no longer in the store — deleted here or anywhere — leaves the stack by the stack's own
/// state (`trail`, the Collections tab's path), drawn as it last was on the way out.
///
/// **Journal** (MEMNG-718). The `Journal` chip swaps the grid for the trip's memos, oldest first
/// as the server read them (`TripMembershipStore.loadJournal`), as the Timeline's `MemoCard`s under
/// the Timeline's own day headings. A card opens its memo through `MemoJump`, the request the
/// Library and this screen's viewer already make: `MemoDetailView` edits through the Timeline's
/// store, which lives on the Timeline's stack alone, so the memo is pushed there as the same
/// `MemoRoute` a Timeline card pushes — never a second detail screen on this stack. A card's
/// PHOTO stays on the trip (MEMNG-769): it opens the viewer here, over that memo's own pictures,
/// with the trip's Use as Cover row (`journalOpening`).
///
/// **Map** (MEMNG-719). The `Map` chip swaps the grid for the trip's located members on the Places
/// map (`TripMapScreen`): every marker the account can see, kept only where its uid is one of the
/// drained members (`TripMapPresentation`), with the Places tab's own map, sheet and viewers.
///
/// **Select** (MEMNG-721). The Library's select mode on the trip's grid, in Photos: the Library's
/// own `LibrarySelection` and `LibrarySelectToolbar`, with Share and with Delete for the member's
/// own pictures only (`LibrarySelection.deletable`), run through `TripMembershipStore.delete`. The
/// toolbar stands where the main bar stood because select mode claims the dock (`DockClaim.select`)
/// and the dock's one bottom bar on Collections is then select mode's (`DockBar.standing`) — the
/// same value the main bar is drawn from, so the two never stand together.
///
/// **Remove from Trip** (MEMNG-722). Select mode's toolbar gains Remove on a trip: the chosen
/// pictures leave this trip on this device (`TripMembershipStore.remove`, the record's
/// exclusions), and the grid, the hero, the viewer and the root's card all recompute from the
/// same filtered members. Nothing is sent — the memo keeps its text and its tag. Manage's Show
/// Removed lists the removed pictures the trip's drain still holds (`TripRemovedList`), each with
/// Add Back.
struct TripView: View {
    let record: CollectionRecord
    let collections: CollectionStore
    let trips: TripMembershipStore
    /// Whose trip this is; a change reads it again.
    let subject: String?
    /// The session's handle and server when a read is issued, or nil when there is none.
    let access: () -> CollectionsAccess?
    /// The stack this screen was pushed onto, which it leaves once its trip is gone.
    let trail: Binding<[TripRoute]>
    @State private var manage: TripManage
    /// The chip that is chosen: Photos until somebody picks another.
    @State private var mode = TripMode.photos
    /// Whether Trip Dates is up.
    @State private var editingSpan = false

    /// Optional: a test hosts the screen without a session, and has nothing to download with.
    @Environment(SessionStore.self) private var session: SessionStore?
    @Environment(\.locale) private var locale
    /// The app's bottom chrome, which the grid's scroll folds and unfolds; nil in a harness.
    @Environment(AppDock.self) private var dock: AppDock?
    @Environment(\.timeZone) private var timeZone
    /// Where a journal card's memo is asked for; nil in a harness without the tabs.
    @Environment(MemoJump.self) private var jump: MemoJump?
    /// The picture a tile tap opened, full screen.
    @State private var viewing: MediaViewerSelection?
    /// The picture a Journal card's tap opened, full screen, over that memo's own pictures. Apart
    /// from `viewing` because that viewer's pages are the trip's members, re-read as they change.
    @State private var journalViewing: MediaViewerSelection?
    /// What the open viewer has been handed since it opened, beyond its own pages; emptied
    /// whenever the viewer changes, so it only ever speaks for the one open now.
    @State private var held: Set<String> = []
    /// The download a tile's menu starts, and the sheet it ends in.
    @State private var saving = MediaSaveFlow()
    /// Select mode on the grid, and what it has chosen.
    @State private var selection = LibrarySelection()
    /// Select mode's Share: the chosen originals, fetched one by one into one sheet.
    @State private var sharing = MediaBatchShareFlow()
    /// The running share batch, cancelled when select mode ends so its download stops early.
    @State private var shareTask: Task<Void, Never>?
    /// Select mode's Delete: the question, and the run its yes starts.
    @State private var deleting = LibraryDeleteFlow()
    /// This screen's claim on the dock while select mode's toolbar stands in the main bar's place.
    @State private var dockClaim = UUID()
    /// Manage's Show Removed is up.
    @State private var showingRemoved = false
    @Namespace private var zoom
    /// What the viewer fetches its stills through; a test hands in one it can watch.
    private let viewerTransport: any MediaTransport
    /// Where select mode's Share fetches the chosen originals; nil for the session's own lane. A
    /// test hands in one it can watch and hold.
    private let shareLane: TripShareLane?
    /// The clock Pin and Unpin are judged and written by.
    private let now: () -> Date

    init(
        record: CollectionRecord,
        collections: CollectionStore,
        trips: TripMembershipStore,
        subject: String?,
        access: @escaping () -> CollectionsAccess?,
        trail: Binding<[TripRoute]> = .constant([]),
        manage: TripManage = TripManage(),
        viewerTransport: any MediaTransport = MediaSession.shared,
        shareLane: TripShareLane? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.record = record
        self.collections = collections
        self.trips = trips
        self.subject = subject
        self.access = access
        self.trail = trail
        _manage = State(initialValue: manage)
        self.viewerTransport = viewerTransport
        self.shareLane = shareLane
        self.now = now
    }

    /// The toolbar menu's name, read by VoiceOver.
    static let manageButton = "Manage"
    /// Select mode's way in and out, named as the Library's header names them.
    static let selectButton = "Select"
    static let closeButton = "Close"
    static let renameButton = "Rename"
    /// The Manage item that opens the trip's span.
    static let spanButton = TripSpanSheet.title
    static let pinButton = "Pin"
    static let unpinButton = "Unpin"
    static let moveUpButton = "Move Up"
    static let moveDownButton = "Move Down"
    static let showRemovedButton = "Show Removed"
    /// How long a trip that is gone stays up before the screen leaves: longer than an alert takes
    /// to go.
    static let leavingDelay = Duration.milliseconds(600)
    static let deleteButton = "Delete Trip"
    /// What the rename alert asks.
    static let renameTitle = "Rename Trip"
    /// What a drained trip with no picture left says.
    static let emptyTitle = "No photos in this trip"
    /// What a journal read with no memo under the trip's tag says.
    static let journalEmptyTitle = "No memos in this trip"
    /// The hero's cover, read by VoiceOver.
    static let coverLabel = "Cover"
    /// What the delete dialog says under its question.
    static let deleteExplanation = "The trip goes. Its photos and memos stay."

    /// The hero cover's identifier when it draws `uid`.
    static func coverIdentifier(_ uid: String) -> String { "trip-cover-\(uid)" }

    /// The viewer's action on a trip's picture, read by VoiceOver (MEMNG-720).
    static let useAsCoverButton = "Use as Cover"

    /// What a viewer opened from trip `id` — its grid, or its Map's pins and sheet — offers on the
    /// page on screen: that picture becomes the trip's cover (`CollectionStore.setCover`). The
    /// trip's viewers are the only ones handed it; the Library's, the Timeline's, a memo's and the
    /// Places tab's are handed nil.
    static func useAsCover(_ id: UUID, in collections: CollectionStore) -> MediaViewerHostAction {
        MediaViewerHostAction(title: useAsCoverButton, symbol: "photo.badge.checkmark") {
            collections.setCover(id: id, uid: $0.uid)
        }
    }

    /// The delete dialog's question.
    static func deleteQuestion(_ title: String) -> String { "Delete “\(title)”?" }

    /// The footer under the grid: the cap, only when the drain stopped at it.
    static func capNote(_ state: TripMembershipState, cap: Int = TripMembershipStore.memberCap)
        -> String?
    {
        state == .truncated ? "Showing the first \(cap) photos of this trip" : nil
    }

    /// The footer of a journal that stopped at the cap: it counts memos, not photos.
    static func journalCapNote(
        _ state: TripMembershipState, cap: Int = TripMembershipStore.memberCap
    ) -> String? {
        state == .truncated ? "Showing the first \(cap) memos of this trip" : nil
    }

    /// What a tap on a Journal card opens (MEMNG-769).
    enum JournalOpening: Equatable {
        /// The viewer, on this trip's screen.
        case viewer(MediaViewerSelection)
        /// The memo, on the Timeline, through `MemoJump`.
        case memo(String)
    }

    /// A card's text — `attachment` nil — opens the memo on the Timeline, whose store
    /// `MemoDetailView` edits through. A card's picture opens the viewer over that memo's own
    /// pictures, at the one tapped, and each page carries the memo's uid so it offers Show Memo as
    /// a grid page does. One the viewer cannot show falls back to the memo, because a tap that does
    /// nothing reads as a broken card.
    static func journalOpening(_ attachment: MemoAttachment?, of memo: Memo) -> JournalOpening {
        guard let attachment else { return .memo(memo.uid) }
        let owned = memo.attachments.map { file in
            var file = file
            file.memoUID = memo.uid
            return file
        }
        let selection = MediaViewerPresentation.viewer(for: owned, startingAt: attachment.uid)
        return selection.map(JournalOpening.viewer) ?? .memo(memo.uid)
    }

    /// The Journal viewer's pages: the ones it opened with, each taking the copy of it the trip's
    /// latest read holds, so a signature that lapsed is renewed by `TripURLRefresher` — which
    /// reads the trip again, every kind of file, removed pictures included. A page the trip holds
    /// no row for keeps the copy the memo read gave it. Each keeps its memo, for Show Memo.
    static func journalViewerSource(
        for selection: MediaViewerSelection, renewed rows: [LibraryRow]
    ) -> MediaViewerSource {
        let latest = Dictionary(
            rows.map { ($0.id, $0.attachment) }, uniquingKeysWith: { first, _ in first })
        let files = selection.pages.map { page in
            guard var file = latest[page.id] else { return page.attachment }
            file.memoUID = page.memoUID
            return file
        }
        return .fixed(MediaViewerPresentation.pages(for: files))
    }

    /// What the viewer pages through: the trip's members as the store holds them NOW, as pages —
    /// so a trip read again for fresh signatures reaches a viewer already open over it, each page
    /// taking the copy signed last. The pages it was opened with stand in only while the store
    /// holds no reading of the trip (`loaded` false); a reading that is EMPTY is the answer, and
    /// brings none of them back. `.fixed` over the filtered members, never `.library`: that would
    /// bring excluded ones back.
    static func viewerSource(
        for selection: MediaViewerSelection, members: [LibraryRow], loaded: Bool
    ) -> MediaViewerSource {
        guard loaded else { return .fixed(selection.pages) }
        return .fixed(MediaViewerPresentation.pages(for: members.map(\.attachment)))
    }

    /// Every picture the viewer open on `selection` may be holding: the pages it opened with,
    /// `earlier`, and — once the store holds a reading of the trip — that reading's members. The
    /// viewer is handed nothing else (`viewerSource`), and it keeps a page it was handed when its
    /// source changes under it (`MediaViewerPager.extended`), so any of these can be on screen.
    static func viewerHolds(
        _ selection: MediaViewerSelection, earlier: Set<String>, members: [LibraryRow],
        loaded: Bool
    ) -> Set<String> {
        var held = earlier.union(selection.pages.map(\.id))
        if loaded { held.formUnion(members.map(\.id)) }
        return held
    }

    /// Whether the viewer open on `selection` has outlived what it shows: the trip has been read,
    /// and a picture the viewer may be holding — one it opened with, or one of `holding`, what it
    /// was handed since — is not among the members: the trip read empty, or a picture excluded or
    /// untagged. ANY such picture, not only the one it opened on: the reader may have paged to
    /// another. Such a viewer is closed rather than left showing pictures that are no longer the
    /// trip's — it keeps the pages in front of somebody when its source changes under them
    /// (`MediaViewerPager.extended`), so only closing takes them away.
    static func viewerOutlived(
        _ selection: MediaViewerSelection, holding: Set<String>, members: [LibraryRow],
        loaded: Bool
    ) -> Bool {
        guard loaded else { return false }
        let now = Set(members.map(\.id))
        return !holding.union(selection.pages.map(\.id)).isSubset(of: now)
    }

    /// The record as the store holds it now, or nil once it is gone.
    private var live: CollectionRecord? {
        collections.records.first { $0.id == record.id }
    }

    var body: some View {
        // The trip as it was while its screen leaves: a delete takes it out of the store before
        // the stack has popped, and a body that dropped the grid would drop the alert on it in
        // the middle of the alert's own exit — after which the stack never popped.
        let shown = live ?? record
        // Read here, in the body, so a drain that lands re-presents the viewer's source as well.
        let members = trips.members(for: shown)
        let loaded = trips.summary(for: shown) != nil
        modeContent(shown)
            .background(Color(.systemGroupedBackground))
            // On the grid; the rename alert, the file sheet and the viewer's cover each on a view
            // of their own: one presentation per view. An alert rather than a confirmation dialog,
            // for the reason `ComposeView.deleteRow` records: the dialog put its Cancel neither on
            // screen nor in the accessibility tree.
            .alert(Self.deleteQuestion(shown.title), isPresented: asking(.delete)) {
                Button(Self.deleteButton, role: .destructive) {
                    manage.confirmDelete(record.id, in: collections, forgetting: trips)
                }
                Button("Cancel", role: .cancel) { manage.cancel() }
            } message: {
                Text(Self.deleteExplanation)
            }
            .background {
                Color.clear.alert(Self.renameTitle, isPresented: asking(.rename)) {
                    TextField(Self.renameTitle, text: $manage.draft)
                    Button(Self.renameButton) {
                        manage.confirmRename(record.id, in: collections)
                    }
                    Button("Cancel", role: .cancel) { manage.cancel() }
                }
            }
            .background { Color.clear.fetchingFile(saving) }
            .background {
                Color.clear.sheet(isPresented: $showingRemoved) {
                    NavigationStack {
                        TripRemovedList(record: shown, collections: collections, trips: trips)
                    }
                }
            }
            .background {
                Color.clear.sheet(isPresented: $editingSpan) {
                    TripSpanSheet(record: live ?? record, collections: collections, now: now())
                }
            }
            .navigationTitle(shown.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selection.isActive {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(selection.coversAll(in: members) ? "Deselect All" : "Select All") {
                            selection.toggleAll(in: members)
                        }
                        Button(Self.closeButton, systemImage: "xmark") { selection.close() }
                    }
                } else {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if mode == .photos {
                            Button(Self.selectButton) { selection.begin() }
                        }
                        manageMenu
                    }
                }
            }
            // Select mode's toolbar, in the main bar's place: it stands when the dock's one bottom
            // bar on Collections is `select` — this screen's claim (`dockClaim`) — the same value
            // the main bar is drawn from, so the main bar is not drawn beside it.
            .safeAreaBar(edge: .bottom) {
                if bottomBar == .select { selectBar }
            }
            .gridViewer(
                $viewing, refresher: refresher, zoom: zoom, transport: viewerTransport,
                action: Self.useAsCover(record.id, in: collections)
            ) {
                Self.viewerSource(for: $0, members: members, loaded: loaded)
            }
            .onChange(of: viewing) { _, _ in held = [] }
            // A picture that leaves the trip leaves the selection with it.
            .onChange(of: members) { _, now in selection.prune(keeping: now) }
            // Select mode belongs to the grid: Journal or Map ends it.
            .onChange(of: mode) { _, now in
                if now != .photos { selection.close() }
            }
            // Every way select mode ends comes through here, and each abandons a share still
            // fetching, so it can never offer its files later.
            .onChange(of: selection.isActive) { _, active in
                if active {
                    dock?.claim(dockClaim, for: .select)
                } else {
                    endSelect()
                }
            }
            // The dock is one for every tab: a claim left behind would take the bar off them all.
            .onDisappear {
                selection.close()
                endSelect()
            }
            .onChange(of: ViewerFit(members: members.map(\.id), loaded: loaded)) { _, fit in
                guard let open = viewing else { return }
                let now = trips.members(for: shown)
                if Self.viewerOutlived(open, holding: held, members: now, loaded: fit.loaded) {
                    viewing = nil
                } else {
                    held = Self.viewerHolds(open, earlier: held, members: now, loaded: fit.loaded)
                }
            }
            .task(
                id: DrainKey(
                    subject: subject, id: record.id, tag: live?.tags.first, span: live?.span)
            ) {
                await drain()
            }
            // Read when the chip is chosen, and again whenever it is chosen anew, the account or
            // the tag changes; a load already on the wire is joined.
            .task(
                id: JournalKey(
                    subject: subject, id: record.id, tag: live?.tags.first, span: live?.span,
                    shown: mode == .journal)
            ) {
                guard mode == .journal else { return }
                await loadJournal()
            }
            // Asked here, on the screen that is up: the root under it is off the window, and hears
            // of the change only once it is back. And asked a beat later: the trip's own Delete is
            // answered from an alert that is still on its way out, and a stack asked to pop while a
            // presentation is moving refuses ("the navigation stack will not be updated") while
            // its path says it did — leaving this screen up over a path that no longer holds it.
            .task(id: live == nil) {
                guard live == nil else { return }
                try? await Task.sleep(for: Self.leavingDelay)
                guard !Task.isCancelled else { return }
                let ids = collections.records.map(\.id)
                let kept = CollectionsPresentation.trail(trail.wrappedValue, keeping: ids)
                if kept != trail.wrappedValue { trail.wrappedValue = kept }
            }
    }

    /// The chosen mode's content: the grid, the journal, or the map.
    @ViewBuilder
    private func modeContent(_ live: CollectionRecord) -> some View {
        switch mode {
        case .photos: grid(live)
        case .journal: journal(live)
        case .map: tripMap(live)
        }
    }

    /// The trip's members that know where they were taken, on the Places map (MEMNG-719): the
    /// hero above it, so the chips stay in reach. Keyed on the account, so a change of account
    /// drops the map's markers, sheet and viewer with its store (`TripMapScreen`).
    private func tripMap(_ live: CollectionRecord) -> some View {
        TripMapScreen(
            record: live, trips: trips, access: access, redrain: { await drain() },
            viewerAction: Self.useAsCover(record.id, in: collections),
            hero: { hero(live, members: trips.members(for: live)) }
        )
        .id(subject)
    }

    /// The trip's memos oldest first, one `MemoCard` each, under a heading per day.
    private func journal(_ live: CollectionRecord) -> some View {
        let memos = trips.journal(for: live)
        // Read in the body, so a re-read of the trip re-presents the Journal viewer's pages.
        let renewed = trips.members(for: live) + trips.removedMembers(for: live)
        let state = trips.journalState(for: live)
        let calendar = journalCalendar
        return List {
            hero(live, members: trips.members(for: live))
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if let error = trips.journalError(for: live) {
                NoticeCard(text: error, tone: .error).cardRow()
            }
            ForEach(
                TimelineGrouping.sections(
                    for: memos, calendar: calendar,
                    instant: TripMembershipStore.journalInstant(of:))
            ) { section in
                Section {
                    ForEach(section.memos) { memo in
                        MemoCard(
                            memo: memo,
                            mediaZoom: zoom,
                            openMemo: { open(Self.journalOpening(nil, of: memo)) },
                            openAttachment: { open(Self.journalOpening($0, of: memo)) }
                        )
                        .cardRow()
                    }
                } header: {
                    SectionHeading(
                        title: TimelineGrouping.title(for: section.day, calendar: calendar))
                }
            }
            if state == .draining, memos.isEmpty {
                ProgressView().frame(maxWidth: .infinity).cardRow()
            }
            if let text = journalFooter(live, state: state, empty: memos.isEmpty) {
                TripFooter(text: text).cardRow()
            }
        }
        .listStyle(.plain)
        .feedsDock(dock, on: .collections)
        // On the list, not beside the grid's viewer: one presentation per view. Re-signed as the
        // grid's viewer is, by reading the trip again; its pages take the copies that read holds.
        .gridViewer(
            $journalViewing, refresher: refresher, zoom: zoom, transport: viewerTransport,
            action: Self.useAsCover(record.id, in: collections)
        ) { Self.journalViewerSource(for: $0, renewed: renewed) }
    }

    /// Where a Journal card's tap goes: the viewer here, or the memo on the Timeline.
    private func open(_ opening: JournalOpening) {
        switch opening {
        case .viewer(let selection): journalViewing = selection
        case .memo(let uid): jump?.request(uid)
        }
    }

    /// The day a memo falls on, cut where the screen is: its zone and its language.
    private var journalCalendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    /// What stands under the last memo: the cap note when the load stopped at the cap, else the
    /// empty line when a load answered with nothing — never over a failure, which says its own.
    private func journalFooter(
        _ live: CollectionRecord, state: TripMembershipState, empty: Bool
    ) -> String? {
        if let note = Self.journalCapNote(state, cap: trips.memberCap) { return note }
        let read = state == .complete || state == .truncated
        let failed = trips.journalError(for: live) != nil
        return read && empty && !failed ? Self.journalEmptyTitle : nil
    }

    private func grid(_ live: CollectionRecord) -> some View {
        let members = trips.members(for: live)
        let state = trips.state(for: live)
        return LibraryGrid(
            items: members,
            errorText: trips.lastError,
            loadingMore: state == .draining,
            zoom: zoom,
            // The drain read the whole trip: there is never a next page to ask for.
            wantsMore: { _ in false },
            open: { viewing = MediaGridHosting.viewing($0, in: members) },
            fetch: { file, rendition in
                await MediaGridHosting.fetch(file, rendition, saving: saving, session: session)
            },
            loadMore: {},
            selection: selection,
            toggle: { selection.toggle($0) },
            above: AnyView(hero(live, members: members)),
            below: footerText(state: state, empty: members.isEmpty).map {
                AnyView(TripFooter(text: $0))
            },
            grouping: .flat
        )
        .environment(\.signedURLRefresher, refresher)
        // The reader's scroll folds and unfolds the main bar, as the Timeline's does: told as the
        // Collections tab's, so it counts only while that tab is on screen (MEMNG-715).
        .feedsDock(dock, on: .collections)
    }

    private func hero(_ live: CollectionRecord, members: [LibraryRow]) -> some View {
        let summary = trips.summary(for: live)
        let cover = summary?.coverUid.flatMap { uid in members.first { $0.id == uid } }
        return VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            TripCover(cover: cover)
            Text(live.title)
                .font(.largeTitle.bold())
                .lineLimit(2)
            if let detail = CollectionsPresentation.cardDetail(
                summary ?? live.lastSummary, locale: locale, timeZone: timeZone)
            {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            TripModeRow(chosen: mode) { mode = $0 }
                .padding(.top, DesignTokens.Space.tight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Space.roomy)
        .padding(.bottom, DesignTokens.Space.regular)
    }

    /// What stands under the last picture: the cap note when the drain stopped at the cap, else
    /// the empty line when a drain answered with nothing left — never over a failure, whose
    /// notice is the grid's own.
    private func footerText(state: TripMembershipState, empty: Bool) -> String? {
        if let note = Self.capNote(state, cap: trips.memberCap) { return note }
        let drained = state == .complete || state == .truncated
        return drained && empty && trips.lastError == nil ? Self.emptyTitle : nil
    }

    /// The one bar at the trip's foot (`AppDock.bar(on:)`). Hosted with no dock — a test that shows
    /// the trip alone — the same rule is asked of select mode's claim alone.
    private var bottomBar: DockBar {
        if let dock { return dock.bar(on: .collections) }
        return DockBar.standing(
            mode: .initial, on: .collections, claim: selection.isActive ? .select : nil)
    }

    /// The trip's members as the store holds them now: what a tap of the toolbar acts on.
    private var currentMembers: [LibraryRow] {
        trips.members(for: live ?? record)
    }

    /// Select mode's toolbar, the toast of the last delete run over it, and the delete question.
    private var selectBar: some View {
        let members = currentMembers
        return VStack(spacing: DesignTokens.Space.tight) {
            if let message = deleting.message {
                LibraryDeleteToast(text: message) { deleting.dismissMessage() }
            }
            LibrarySelectToolbar(
                count: selection.count,
                ownCount: selection.deletable(in: members).own.count,
                isSharing: sharing.isSharing,
                isDeleting: deleteRunning,
                share: { shareSelection() },
                // Only the chosen pictures that are mine, as in the Library.
                delete: { deleting.claim(LibraryDeleteFlow.tap(selection, in: currentMembers)) },
                remove: { removeSelection() }
            )
            .sharingFiles(sharing)
        }
        // On the stack around the toolbar, not on the toolbar that carries the share sheet: two
        // presentations on one view is how one of them stops appearing.
        .alert(
            LibraryDeleteFlow.question(
                count: deleting.asking?.count ?? 0, skipped: deleting.skipping),
            isPresented: askingDelete
        ) {
            Button(LibraryDeleteFlow.confirmTitle, role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { deleting.claim(.cancelled) }
        } message: {
            Text(LibraryDeleteFlow.explanation)
        }
    }

    /// A delete run is out — this screen's, or one an abandoned select mode left running.
    private var deleteRunning: Bool {
        deleting.isDeleting || trips.isDeleting
    }

    private var askingDelete: Binding<Bool> {
        Binding(
            get: { deleting.asking != nil },
            set: { if !$0 { deleting.claim(.cancelled) } }
        )
    }

    /// The alert's yes: the handle is taken here, at the answer, and the whole run goes out on it
    /// (`TripMembershipStore.delete`), claimed synchronously before any task. A run already sent
    /// is let finish when select mode ends; only its answer stops counting (`abandon`).
    private func confirmDelete() {
        guard let handle = access()?.handle else {
            deleting.claim(.cancelled)
            return
        }
        guard deleting.claim(.confirmed) else { return }
        Task {
            await deleting.perform { uids in await trips.delete(uids, using: handle) }
        }
    }

    /// Select mode's Share: the chosen rows, in the order they were chosen, each fetched as its
    /// ORIGINAL through the session's download lane, fenced by the session generation it started
    /// under (`MediaBatchShareFlow`). With no session there is nothing to fetch with.
    private func shareSelection() {
        guard let lane = shareLane ?? session.map(TripShareLane.session) else { return }
        let rows = selection.rows(in: currentMembers)
        shareTask = Task {
            _ = await sharing.share(rows, generation: lane.generation, download: lane.download)
        }
    }

    /// Select mode's Remove from Trip: the chosen pictures leave this trip at once, and the
    /// selection with them — select mode stays, holding nothing, as after a Delete.
    private func removeSelection() {
        let chosen = selection.rows(in: currentMembers).map(\.id)
        trips.remove(chosen, from: record.id)
        selection.prune(keeping: currentMembers)
    }

    /// Select mode ended: a share still fetching stops being the live one and its task is
    /// cancelled, an open question closes, and the dock is given back.
    private func endSelect() {
        sharing.abandon()
        shareTask?.cancel()
        shareTask = nil
        deleting.abandon()
        dock?.release(dockClaim)
    }

    private var manageMenu: some View {
        Menu(Self.manageButton, systemImage: "ellipsis.circle") {
            Button(Self.renameButton, systemImage: "pencil") {
                manage.askRename(current: live?.title ?? record.title)
            }
            Button(Self.spanButton, systemImage: "calendar") { editingSpan = true }
            let pinAction = TripManage.pinAction(of: record.id, in: collections, now: now())
            Button(pinAction.title, systemImage: pinAction.symbol) {
                manage.apply(pinAction, to: record.id, in: collections, now: now())
            }
            Button(Self.moveUpButton, systemImage: "arrow.up") {
                manage.move(record.id, .up, in: collections)
            }
            .disabled(TripManage.moveTarget(of: record.id, .up, in: collections.records) == nil)
            Button(Self.moveDownButton, systemImage: "arrow.down") {
                manage.move(record.id, .down, in: collections)
            }
            .disabled(TripManage.moveTarget(of: record.id, .down, in: collections.records) == nil)
            Button(Self.showRemovedButton, systemImage: "eye.slash") { showingRemoved = true }
                .disabled(trips.removedMembers(for: live ?? record).isEmpty)
            Divider()
            Button(Self.deleteButton, systemImage: "trash", role: .destructive) {
                manage.askDelete()
            }
        }
    }

    /// Whether `question` is on screen. Its going away — a button, or a tap outside — takes it
    /// off the screen only; what the answer may still do is the flow's (`TripManage`).
    private func asking(_ question: TripManage.Question) -> Binding<Bool> {
        Binding(
            get: { manage.question == question },
            set: { if !$0 { manage.dismissed(question) } }
        )
    }

    /// Who re-signs a lapsed picture of the trip: a read of the trip again.
    private var refresher: TripURLRefresher {
        let access = access
        return TripURLRefresher(
            trips: trips,
            collections: collections,
            id: record.id,
            session: IssuingSession(handle: { access()?.handle }, baseURL: { access()?.baseURL })
        )
    }

    private func drain() async {
        guard let live, let access = access() else { return }
        await trips.drain(live, using: access.handle, baseURL: access.baseURL)
    }

    private func loadJournal() async {
        guard let live, let access = access() else { return }
        await trips.loadJournal(live, using: access.handle, baseURL: access.baseURL)
    }

    /// What decides whether an open viewer still fits the trip.
    private struct ViewerFit: Equatable {
        let members: [String]
        let loaded: Bool
    }

    private struct DrainKey: Equatable {
        let subject: String?
        let id: UUID
        let tag: String?
        let span: TripSpan?
    }

    private struct JournalKey: Equatable {
        let subject: String?
        let id: UUID
        let tag: String?
        let span: TripSpan?
        let shown: Bool
    }
}

/// The hero's picture: the trip's cover, or a placeholder until there is one.
struct TripCover: View {
    let cover: LibraryRow?

    static let height: CGFloat = 240

    var body: some View {
        Group {
            if let cover {
                AttachmentThumbnail(
                    attachment: cover.attachment,
                    tier: .mobile,
                    slot: AttachmentSlot(aspectRatio: 4 / 3, contentMode: .fill),
                    cornerRadius: 0
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TripView.coverLabel)
                .accessibilityIdentifier(TripView.coverIdentifier(cover.id))
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "suitcase")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
    }
}

/// Manage's Show Removed: the trip's removed pictures its drain still holds, oldest first
/// (`TripMembershipStore.removedMembers`), each with Add Back. A removed picture the drain no
/// longer holds — deleted, or its memo no longer tagged — is not listed, and stays removed.
struct TripRemovedList: View {
    let record: CollectionRecord
    let collections: CollectionStore
    let trips: TripMembershipStore

    @Environment(\.dismiss) private var dismiss

    static let title = "Removed"
    static let addBackButton = "Add Back"
    static let emptyTitle = "No removed photos"
    /// A removed picture's thumbnail side.
    static let thumbnail: CGFloat = 56

    var body: some View {
        let live = collections.records.first { $0.id == record.id } ?? record
        let rows = trips.removedMembers(for: live)
        List {
            if rows.isEmpty {
                Text(Self.emptyTitle)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(spacing: DesignTokens.Space.regular) {
                    AttachmentThumbnail(
                        attachment: row.attachment,
                        tier: .thumb,
                        slot: AttachmentSlot(aspectRatio: 1, contentMode: .fill),
                        cornerRadius: DesignTokens.Radius.tile
                    )
                    .frame(width: Self.thumbnail, height: Self.thumbnail)
                    .accessibilityHidden(true)
                    Group {
                        if let taken = row.takenAt {
                            Text(taken, format: .dateTime.day().month().year().hour().minute())
                        } else {
                            Text(row.filename)
                        }
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                    Spacer(minLength: DesignTokens.Space.snug)
                    // Borderless: a default-styled button in a row is pressed by a tap anywhere
                    // in that row.
                    Button(Self.addBackButton) { trips.addBack(row.id, to: record.id) }
                        .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// The line under a trip's grid.
struct TripFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(DesignTokens.Space.roomy)
    }
}

/// A trip's modes: Photos, Journal (MEMNG-718) and Map (MEMNG-719), every one open.
enum TripMode: CaseIterable, Hashable {
    case photos, journal, map

    var title: String {
        switch self {
        case .photos: "Photos"
        case .journal: "Journal"
        case .map: "Map"
        }
    }

    var isAvailable: Bool { true }
}

/// The `Photos | Journal | Map` chips under the hero: the chosen one marked, a press choosing.
struct TripModeRow: View {
    let chosen: TripMode
    let choose: (TripMode) -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.snug) {
            ForEach(TripMode.allCases, id: \.self) { mode in
                let chosen = mode == self.chosen
                Button(mode.title) { choose(mode) }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, DesignTokens.Space.regular)
                    .padding(.vertical, DesignTokens.Space.snug)
                    .background(
                        chosen
                            ? AnyShapeStyle(DesignTokens.accent.opacity(0.2))
                            : AnyShapeStyle(.quaternary),
                        in: .capsule
                    )
                    .disabled(!mode.isAvailable)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}

/// Which way Move Up and Move Down move a trip in the order.
enum TripMoveDirection {
    case up, down
}

/// What the Manage menu's pin item offers: Pin for a trip that is not the active pin (an expired
/// pin included), Unpin for the one that is.
enum TripPinAction: Equatable {
    case pin, unpin

    var title: String { self == .pin ? TripView.pinButton : TripView.unpinButton }
    var symbol: String { self == .pin ? "pin" : "pin.slash" }
}

/// The Trip screen's Manage menu, as a flow: the question on screen, and what its answer may do.
///
/// **An answer is claimed once.** Asking arms the question; the first yes takes it, and a second
/// yes — a double tap, or a yes nobody was asked for — does nothing. The dialog going off the
/// screen does not disarm it, because SwiftUI puts the binding down as the button is tapped, so
/// the order of the two is not this flow's to rely on; a new question re-arms, and Cancel disarms.
@MainActor
@Observable
final class TripManage {
    enum Question: Equatable {
        case rename, delete
    }

    /// The question on screen.
    private(set) var question: Question?
    /// The rename field's text.
    var draft = ""
    /// The question whose yes has not been given yet.
    private var armed: Question?

    func askRename(current: String) {
        draft = current
        ask(.rename)
    }

    func askDelete() { ask(.delete) }

    /// The dialog went off the screen, by whatever means.
    func dismissed(_ question: Question) {
        if self.question == question { self.question = nil }
    }

    func cancel() {
        armed = nil
        question = nil
    }

    /// Rename's yes: the trimmed title, written once. A blank or unchanged title writes nothing.
    @discardableResult
    func confirmRename(_ id: UUID, in collections: CollectionStore) -> Bool {
        guard take(.rename),
            let current = collections.records.first(where: { $0.id == id })?.title,
            let title = Self.renamed(draft, from: current)
        else { return false }
        collections.rename(id: id, to: title)
        return true
    }

    /// Delete's yes: that trip, and only it, once.
    @discardableResult
    func confirmDelete(
        _ id: UUID, in collections: CollectionStore, forgetting trips: TripMembershipStore? = nil
    ) -> Bool {
        guard take(.delete), collections.records.contains(where: { $0.id == id }) else {
            return false
        }
        collections.delete(id: id)
        trips?.forget(id)
        return true
    }

    /// Moves the trip one place up or down the order; at the end it stays.
    func move(_ id: UUID, _ direction: TripMoveDirection, in collections: CollectionStore) {
        guard let target = Self.moveTarget(of: id, direction, in: collections.records) else {
            return
        }
        collections.move(id: id, to: target)
    }

    /// What the pin item offers for the trip at `now`: Unpin when it is the scope's active pin,
    /// else Pin.
    static func pinAction(
        of id: UUID, in collections: CollectionStore, now: Date
    ) -> TripPinAction {
        collections.activePin(now: now)?.id == id ? .unpin : .pin
    }

    /// Does what the item offered, never the opposite: a Pin tapped twice pins once (the second
    /// write is the same pin), and an Unpin tapped twice leaves the trip unpinned. Not a toggle,
    /// so a second tap cannot undo the first. A trip that has left the store is not written.
    func apply(
        _ action: TripPinAction, to id: UUID, in collections: CollectionStore, now: Date
    ) {
        guard collections.records.contains(where: { $0.id == id }) else { return }
        switch action {
        case .pin: collections.pin(id: id, now: now)
        case .unpin: collections.unpin(id: id)
        }
    }

    /// Where a move would put the trip, or nil when it is already at that end (or not a trip).
    static func moveTarget(
        of id: UUID, _ direction: TripMoveDirection, in records: [CollectionRecord]
    ) -> Int? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        let target = direction == .up ? index - 1 : index + 1
        return records.indices.contains(target) ? target : nil
    }

    /// The title a rename writes: the draft trimmed, or nil when that is blank or unchanged.
    static func renamed(_ draft: String, from current: String) -> String? {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != current else { return nil }
        return title
    }

    private func ask(_ next: Question) {
        armed = next
        question = next
    }

    private func take(_ answer: Question) -> Bool {
        guard armed == answer else { return false }
        armed = nil
        question = nil
        return true
    }
}

/// Where the Trip screen's Share fetches the chosen originals: the session's generation, which
/// fences the batch, and its download lane (`SessionStore.download`).
struct TripShareLane {
    let generation: @MainActor () -> Int?
    let download: @MainActor (MemoAttachment, AttachmentRendition) async throws -> URL

    static func session(_ session: SessionStore) -> TripShareLane {
        TripShareLane(
            generation: { session.activeHandle?.generation },
            download: { file, rendition in try await session.download(file, rendition) }
        )
    }
}
