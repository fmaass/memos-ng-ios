import MemosCore
import SwiftUI

/// What the Collections root pushes for a trip card: the trip, known by its id.
struct TripRoute: Hashable {
    let id: String
    /// The trip as it was when its card was opened. Its screen draws this once the trip has left
    /// the store, while the stack lets the screen go: a destination that drew nothing for a trip
    /// that is gone would take the screen's own way off the stack with it.
    let opened: Trip

    init(_ trip: Trip) {
        id = trip.uid
        opened = trip
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
/// (`TripMemberStore.members(for:)`), which are what the server's member route answers — the
/// server has already taken a removed picture out, so it is absent from the grid, the hero and the
/// viewer alike. No second `MediaLibraryStore` is built: the drain reads the whole trip before anything is
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
/// changes, or the store let the members go (any change to a trip moves the one revision every
/// trip's members belong to); a drain of the same trip already on the wire is joined. While a
/// re-read is on the wire the screen keeps the members it last showed (`TripSettledMembers`), so
/// a change to another trip never empties this one's grid.
///
/// **Manage.** Rename, Trip Dates, Pin or Unpin, Show Removed and Delete Trip, through
/// `TripManage`, whose writes are the server's (`TripStore.update`/`delete`): while one is out the
/// hero shows it, and a write that failed says why under the title. Trip Dates opens
/// `TripSpanSheet`. Pin or Unpin is one item, named by whether this trip is the scope's active pin
/// now (`TripPins.activePin(now:)`), so a pin that has expired offers Pin again. A trip that
/// is no longer in the store — deleted here or anywhere — leaves the stack by the stack's own
/// state (`trail`, the Collections tab's path), drawn as it last was on the way out.
///
/// **Journal** (MEMNG-718). The `Journal` chip swaps the grid for the trip's memos, oldest first
/// as the server read them (`TripMemberStore.loadJournal`), as the Timeline's `MemoCard`s under
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
/// own pictures only (`LibrarySelection.deletable`), run through `TripMemberStore.delete`. The
/// toolbar stands where the main bar stood because select mode claims the dock (`DockClaim.select`)
/// and the dock's one bottom bar on Collections is then select mode's (`DockBar.standing`) — the
/// same value the main bar is drawn from, so the two never stand together.
///
/// **Remove from Trip** (MEMNG-722). Select mode's toolbar gains Remove on a trip: the chosen
/// pictures leave this trip on the server (`TripMemberStore.remove`, one exclusion per picture,
/// then the record and the members read again), and the grid, the hero, the viewer and the root's
/// card follow the answer. The memo keeps its text and its tag. Manage's Show Removed is always
/// offered: its sheet computes the removed pictures when it opens (`TripRemovedList`), each with
/// Add Back.
struct TripView: View {
    let trip: Trip
    let trips: TripStore
    let memberStore: TripMemberStore
    /// Whose trip this is — the server and the subject; a change reads it again, and lets go of
    /// everything the outgoing account was shown.
    let identity: TimelineSnapshotIdentity?
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
    /// The members last shown while they were settled, kept while a re-read is on the wire.
    @State private var settled = TripSettledMembers()
    /// Why the last Remove from Trip did not finish, or nil.
    @State private var removeFailure: String?
    @Namespace private var zoom
    /// What the viewer fetches its stills through; a test hands in one it can watch.
    private let viewerTransport: any MediaTransport
    /// Where select mode's Share fetches the chosen originals; nil for the session's own lane. A
    /// test hands in one it can watch and hold.
    private let shareLane: TripShareLane?
    /// The clock Pin and Unpin are judged and written by.
    private let now: () -> Date

    init(
        trip: Trip,
        trips: TripStore,
        memberStore: TripMemberStore,
        identity: TimelineSnapshotIdentity?,
        access: @escaping () -> CollectionsAccess?,
        trail: Binding<[TripRoute]> = .constant([]),
        manage: TripManage = TripManage(),
        viewerTransport: any MediaTransport = MediaSession.shared,
        shareLane: TripShareLane? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.trip = trip
        self.trips = trips
        self.memberStore = memberStore
        self.identity = identity
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
    /// page on screen: that picture becomes the trip's cover on the server (`TripManage.setCover`,
    /// a `TripStore.update`). The trip's viewers are the only ones handed it; the Library's, the
    /// Timeline's, a memo's and the Places tab's are handed nil.
    static func useAsCover(
        _ uid: String, in trips: TripStore, manage: TripManage,
        access: @escaping () -> CollectionsAccess?
    ) -> MediaViewerHostAction {
        MediaViewerHostAction(title: useAsCoverButton, symbol: "photo.badge.checkmark") {
            manage.setCover($0.uid, of: uid, in: trips, using: access())
        }
    }

    /// The line under the title while a change to the trip is out.
    static let savingLine = "Saving…"
    /// The identifiers of the hero's saving and error lines.
    static let savingLineID = "trip-saving"
    static let errorLineID = "trip-error"

    /// The delete dialog's question.
    static func deleteQuestion(_ title: String) -> String { "Delete “\(title)”?" }

    /// The footer under the grid: the cap, only when the drain stopped at it.
    static func capNote(_ state: TripMemberState, cap: Int = TripMemberStore.memberCap)
        -> String?
    {
        state == .truncated ? "Showing the first \(cap) photos of this trip" : nil
    }

    /// The footer of a journal that stopped at the cap: it counts memos, not photos.
    static func journalCapNote(
        _ state: TripMemberState, cap: Int = TripMemberStore.memberCap
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
    /// journal holds now, so a signature that lapsed is renewed by `TripJournalURLRefresher`,
    /// which reads the journal again. The journal's memos carry every picture they hold, a member
    /// or one removed from the trip, so the renewal never depends on the members or the Removed
    /// list. A page no memo holds any more keeps the copy it had. Each keeps its memo, for Show
    /// Memo.
    static func journalViewerSource(
        for selection: MediaViewerSelection, memos: [Memo]
    ) -> MediaViewerSource {
        let latest = Dictionary(
            memos.flatMap { memo in memo.attachments.map { ($0.uid, $0) } },
            uniquingKeysWith: { first, _ in first })
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

    /// The trip as the store holds it now, or nil once it is gone.
    /// The members as the store holds them, once a drain has settled; nil while none has, or the
    /// store let them go and a re-read is on the wire.
    static func settled(
        of trip: Trip, in store: TripMemberStore, under identity: TimelineSnapshotIdentity?
    ) -> TripSettledMembers? {
        switch store.state(for: trip) {
        case .complete, .truncated:
            TripSettledMembers(
                uid: trip.uid, identity: identity, rows: store.members(for: trip),
                loaded: store.summary(for: trip) != nil)
        case .notLoaded, .draining: nil
        }
    }

    /// The cover the hero draws: the chosen one while it is among `members`, else the first.
    static func cover(of trip: Trip, members: [LibraryRow]) -> LibraryRow? {
        trip.cover.flatMap { cover in members.first { $0.id == cover.id } } ?? members.first
    }

    private var live: Trip? {
        trips.trips.first { $0.uid == trip.uid }
    }

    var body: some View {
        // The trip as it was while its screen leaves: a delete takes it out of the store before
        // the stack has popped, and a body that dropped the grid would drop the alert on it in
        // the middle of the alert's own exit — after which the stack never popped.
        let shown = live ?? trip
        // Read here, in the body, so a drain that lands re-presents the viewer's source as well.
        let fresh = freshMembers(of: shown)
        let current = shownMembers
        let members = current.rows
        let loaded = current.loaded
        modeContent(shown)
            .background(Color(.systemGroupedBackground))
            // On the grid; the rename alert, the file sheet and the viewer's cover each on a view
            // of their own: one presentation per view. An alert rather than a confirmation dialog,
            // for the reason `ComposeView.deleteRow` records: the dialog put its Cancel neither on
            // screen nor in the accessibility tree.
            .alert(Self.deleteQuestion(shown.title), isPresented: asking(.delete)) {
                Button(Self.deleteButton, role: .destructive) {
                    manage.confirmDelete(trip.uid, in: trips, using: access())
                }
                Button("Cancel", role: .cancel) { manage.cancel() }
            } message: {
                Text(Self.deleteExplanation)
            }
            .background {
                Color.clear.alert(Self.renameTitle, isPresented: asking(.rename)) {
                    TextField(Self.renameTitle, text: $manage.draft)
                    Button(Self.renameButton) {
                        manage.confirmRename(trip.uid, in: trips, using: access())
                    }
                    Button("Cancel", role: .cancel) { manage.cancel() }
                }
            }
            .background { Color.clear.fetchingFile(saving) }
            .background {
                Color.clear.sheet(isPresented: $manage.showingRemoved) {
                    NavigationStack {
                        TripRemovedList(
                            trip: shown, trips: trips, members: memberStore, access: access)
                    }
                }
            }
            .background {
                Color.clear.sheet(isPresented: $editingSpan) {
                    TripSpanSheet(
                        trip: live ?? trip, trips: trips, access: access,
                        lastSummary: memberStore.summary(for: live ?? trip), now: now())
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
                action: Self.useAsCover(trip.uid, in: trips, manage: manage, access: access),
                gone: memberStore.deleted
            ) {
                Self.viewerSource(for: $0, members: members, loaded: loaded)
            }
            .onChange(of: viewing) { _, _ in held = [] }
            // What a settled drain answered stands until the next one settles — from the first
            // frame: a trip opened over members already read keeps them while its own read is out.
            .onChange(of: fresh, initial: true) { _, now in
                if let now { settled = now }
            }
            // Another account's screen: no viewer open over the outgoing one's photos, and no
            // selection of them, stays. Its members stay behind their identity (`shownMembers`).
            .onChange(of: identity) {
                viewing = nil
                journalViewing = nil
                held = []
                selection.close()
            }
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
                let now = shownMembers.rows
                if Self.viewerOutlived(open, holding: held, members: now, loaded: fit.loaded) {
                    viewing = nil
                } else {
                    held = Self.viewerHolds(open, earlier: held, members: now, loaded: fit.loaded)
                }
            }
            .task(
                id: DrainKey(
                    identity: identity, id: trip.uid, tag: live?.tag, span: live?.tripSpan)
            ) {
                await drain()
            }
            // The store let the members go — a change to a trip moved its revision — so they are
            // read again; the screen keeps showing the last ones meanwhile.
            .task(id: memberStore.state(for: shown) == .notLoaded) {
                guard memberStore.state(for: shown) == .notLoaded else { return }
                await drain()
            }
            // Read when the chip is chosen, and again whenever it is chosen anew, the account or
            // the tag changes; a load already on the wire is joined.
            .task(
                id: JournalKey(
                    identity: identity, id: trip.uid, tag: live?.tag, span: live?.tripSpan,
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
                let ids = trips.trips.map(\.uid)
                let kept = CollectionsPresentation.trail(trail.wrappedValue, keeping: ids)
                if kept != trail.wrappedValue { trail.wrappedValue = kept }
            }
    }

    /// The chosen mode's content: the grid, the journal, or the map.
    @ViewBuilder
    private func modeContent(_ live: Trip) -> some View {
        switch mode {
        case .photos: grid(live)
        case .journal: journal(live)
        case .map: tripMap(live)
        }
    }

    /// The trip's members that know where they were taken, on the Places map (MEMNG-719): the
    /// hero above it, so the chips stay in reach. Keyed on the account, so a change of account
    /// drops the map's markers, sheet and viewer with its store (`TripMapScreen`).
    private func tripMap(_ live: Trip) -> some View {
        TripMapScreen(
            trip: live, members: memberStore, access: access, redrain: { await drain() },
            viewerAction: Self.useAsCover(trip.uid, in: trips, manage: manage, access: access),
            hero: { hero(live, members: shownMembers.rows) }
        )
        .id(identity)
    }

    /// The trip's memos oldest first, one `MemoCard` each, under a heading per day.
    private func journal(_ live: Trip) -> some View {
        let memos = memberStore.journal(for: live)
        let state = memberStore.journalState(for: live)
        let calendar = journalCalendar
        return List {
            hero(live, members: shownMembers.rows)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if let error = memberStore.journalError(for: live) {
                NoticeCard(text: error, tone: .error).cardRow()
            }
            ForEach(
                TimelineGrouping.sections(
                    for: memos, calendar: calendar,
                    instant: TripMemberStore.journalInstant(of:))
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
        // On the list, not beside the grid's viewer: one presentation per view. Its pages are
        // re-signed by reading the journal again; `memos` is read in the body, so that read
        // re-presents them with its copies.
        .gridViewer(
            $journalViewing, refresher: journalRefresher, zoom: zoom, transport: viewerTransport,
            action: Self.useAsCover(trip.uid, in: trips, manage: manage, access: access),
            gone: memberStore.deleted
        ) { Self.journalViewerSource(for: $0, memos: memos) }
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
        _ live: Trip, state: TripMemberState, empty: Bool
    ) -> String? {
        // A trip of dates alone has no journal: nothing is read, and the chip says why.
        guard live.tag != nil else { return TripMemberStore.noTagJournal }
        if let note = Self.journalCapNote(state, cap: memberStore.memberCap) { return note }
        let read = state == .complete || state == .truncated
        let failed = memberStore.journalError(for: live) != nil
        return read && empty && !failed ? Self.journalEmptyTitle : nil
    }

    private func grid(_ live: Trip) -> some View {
        let members = shownMembers.rows
        let state = memberStore.state(for: live)
        return LibraryGrid(
            items: members,
            errorText: memberStore.lastError,
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

    private func hero(_ live: Trip, members: [LibraryRow]) -> some View {
        let summary = memberStore.summary(for: live)
        return VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            TripCover(cover: Self.cover(of: live, members: members))
            Text(live.title)
                .font(.largeTitle.bold())
                .lineLimit(2)
            Text(
                CollectionsPresentation.tripDetail(
                    live, summary: summary, locale: locale, timeZone: timeZone)
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if manage.isSaving {
                HStack(spacing: DesignTokens.Space.tight) {
                    ProgressView()
                    Text(Self.savingLine)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(Self.savingLineID)
            }
            if let failure = manage.failure ?? removeFailure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(Self.errorLineID)
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
    private func footerText(state: TripMemberState, empty: Bool) -> String? {
        if let note = Self.capNote(state, cap: memberStore.memberCap) { return note }
        let drained = state == .complete || state == .truncated
        return drained && empty && memberStore.lastError == nil ? Self.emptyTitle : nil
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
        shownMembers.rows
    }

    /// What the screen shows (`shown`).
    private var shownMembers: TripSettledMembers {
        let shown = live ?? trip
        return Self.shown(
            shown, fresh: freshMembers(of: shown), settled: settled, identity: identity,
            in: memberStore)
    }

    /// What the screen shows: the store's settled members, else the last settled ones of this
    /// trip and this account while a re-read is on the wire, else none. The ones kept are read
    /// through the store's `stillMembers`, so a removal the server acknowledged, or a Delete,
    /// leaves the screen and the toolbar's reach though no read after it ever lands.
    static func shown(
        _ trip: Trip, fresh: TripSettledMembers?, settled: TripSettledMembers,
        identity: TimelineSnapshotIdentity?, in store: TripMemberStore
    ) -> TripSettledMembers {
        if let fresh { return fresh }
        guard settled.uid == trip.uid, settled.identity == identity else {
            return TripSettledMembers(uid: trip.uid, identity: identity)
        }
        var kept = settled
        kept.rows = store.stillMembers(settled.rows, of: trip)
        return kept
    }

    /// The store's settled members, only while the trip store holds this screen's account: one
    /// that has not moved yet to the account the screen shows still holds the outgoing one's.
    private func freshMembers(of shown: Trip) -> TripSettledMembers? {
        guard identity != nil, trips.identity == identity else { return nil }
        return Self.settled(of: shown, in: memberStore, under: identity)
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
        deleting.isDeleting || memberStore.isDeleting
    }

    private var askingDelete: Binding<Bool> {
        Binding(
            get: { deleting.asking != nil },
            set: { if !$0 { deleting.claim(.cancelled) } }
        )
    }

    /// The alert's yes: the handle is taken here, at the answer, and the whole run goes out on it
    /// (`TripMemberStore.delete`), claimed synchronously before any task. A run already sent
    /// is let finish when select mode ends; only its answer stops counting (`abandon`).
    private func confirmDelete() {
        guard let access = access() else {
            deleting.claim(.cancelled)
            return
        }
        guard deleting.claim(.confirmed) else { return }
        Task {
            await deleting.perform { uids in
                await memberStore.delete(uids, using: access.handle, baseURL: access.baseURL)
            }
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
        guard !chosen.isEmpty, let access = access() else { return }
        let target = live ?? trip
        Task {
            do {
                let outcome = try await memberStore.remove(
                    chosen, from: target, using: access.handle, baseURL: access.baseURL)
                removeFailure = outcome.stopped.flatMap(TripManage.sentence)
            } catch {
                removeFailure = TripManage.sentence(error)
            }
            selection.prune(keeping: currentMembers)
        }
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
                manage.askRename(current: live?.title ?? trip.title)
            }
            Button(Self.spanButton, systemImage: "calendar") { editingSpan = true }
            let pinAction = TripManage.pinAction(of: trip.uid, in: trips, now: now())
            Button(pinAction.title, systemImage: pinAction.symbol) {
                manage.apply(
                    pinAction, to: trip.uid, in: trips,
                    lastTaken: memberStore.summary(for: live ?? trip)?.lastTaken, now: now())
            }
            // Offered before anything is known: its sheet computes the list when it opens.
            Button(Self.showRemovedButton, systemImage: "eye.slash") { manage.showRemoved() }
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
            members: memberStore,
            trips: trips,
            uid: trip.uid,
            session: IssuingSession(handle: { access()?.handle }, baseURL: { access()?.baseURL })
        )
    }

    /// Who re-signs a lapsed picture of the Journal: a read of the journal again.
    private var journalRefresher: TripJournalURLRefresher {
        let access = access
        return TripJournalURLRefresher(
            members: memberStore,
            trips: trips,
            uid: trip.uid,
            session: IssuingSession(handle: { access()?.handle }, baseURL: { access()?.baseURL })
        )
    }

    private func drain() async {
        guard let live, let access = access() else { return }
        await memberStore.drain(live, using: access.handle, baseURL: access.baseURL)
    }

    private func loadJournal() async {
        guard let live, let access = access() else { return }
        await memberStore.loadJournal(live, using: access.handle, baseURL: access.baseURL)
    }

    /// What decides whether an open viewer still fits the trip.
    private struct ViewerFit: Equatable {
        let members: [String]
        let loaded: Bool
    }

    private struct DrainKey: Equatable {
        let identity: TimelineSnapshotIdentity?
        let id: String
        let tag: String?
        let span: TripSpan?
    }

    private struct JournalKey: Equatable {
        let identity: TimelineSnapshotIdentity?
        let id: String
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

/// Manage's Show Removed: the pictures the server excludes from the trip, oldest first, each with
/// Add Back — computed when the sheet opens (`TripMemberStore.removed`), never before. While they
/// are read it says so; the answer is the exact list, "nothing removed", or — when the trip's
/// members could not all be read (past the cap) — that the list is not available, never a guess.
struct TripRemovedList: View {
    let trip: Trip
    let trips: TripStore
    let members: TripMemberStore
    let access: () -> CollectionsAccess?

    @Environment(\.dismiss) private var dismiss
    /// Why the last Add Back did not reach the server, or nil.
    @State private var failure: String?

    static let title = "Removed"
    static let addBackButton = "Add Back"
    /// What the sheet says when the server excludes nothing from the trip.
    static let emptyTitle = "No removed photos"
    /// What it says while the list is computed.
    static let loadingTitle = "Reading the removed photos…"
    /// What it says when the list cannot be exact.
    static let unavailableTitle = "Not available for a trip this large"
    /// A row's thumbnail edge, in points.
    static let thumbnail: CGFloat = 56

    var body: some View {
        let live = trips.trips.first { $0.uid == trip.uid } ?? trip
        List {
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(TripView.errorLineID)
            }
            switch members.removedState(for: live) {
            case .notRequested, .loading:
                HStack {
                    Text(Self.loadingTitle).foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            case .unavailable:
                Text(Self.unavailableTitle).foregroundStyle(.secondary)
            case .exact(let rows) where rows.isEmpty:
                Text(Self.emptyTitle).foregroundStyle(.secondary)
            case .exact(let rows):
                ForEach(rows) { row in self.row(row, of: live) }
            }
        }
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        // Computed when the sheet opens, and again whenever the store let it go (a change to a
        // trip, a refresh, another account).
        .task(id: members.removedState(for: live) == .notRequested) {
            guard members.removedState(for: live) == .notRequested, let access = access() else {
                return
            }
            await members.removed(for: live, using: access.handle, baseURL: access.baseURL)
        }
    }

    private func row(_ row: LibraryRow, of live: Trip) -> some View {
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
            Button(Self.addBackButton) { addBack(row.id, to: live) }
                .buttonStyle(.borderless)
        }
    }

    private func addBack(_ uid: String, to live: Trip) {
        guard let access = access() else { return }
        Task {
            do {
                let outcome = try await members.addBack(
                    uid, to: live, using: access.handle, baseURL: access.baseURL)
                failure = outcome.stopped.flatMap(TripManage.sentence)
            } catch {
                failure = TripManage.sentence(error)
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

    /// The question on screen, or nil.
    private(set) var question: Question?
    /// The rename dialog's field.
    var draft = ""
    /// Why the last change did not reach the server, or nil — said under the trip's title.
    private(set) var failure: String?
    /// The question a yes may still answer.
    private var armed: Question?
    /// How many changes are out.
    private var saving = 0
    /// Manage's Show Removed is up.
    var showingRemoved = false

    /// Whether a rename, delete or cover change is out: the hero says so.
    var isSaving: Bool { saving > 0 }

    func askRename(current: String) {
        draft = current
        ask(.rename)
    }

    func askDelete() { ask(.delete) }

    /// Manage's Show Removed: offered before anything is known, its sheet computes the list.
    func showRemoved() { showingRemoved = true }

    /// The dialog went off the screen without an answer this flow saw: nothing more to show.
    func dismissed(_ question: Question) {
        if self.question == question { self.question = nil }
    }

    func cancel() {
        armed = nil
        question = nil
    }

    /// Renames trip `uid` to the draft, trimmed, on the server — only when the question was armed,
    /// the draft says something and it differs from the title now. The answer is claimed here,
    /// before anything is awaited; the returned task is the write.
    @discardableResult
    func confirmRename(
        _ uid: String, in trips: TripStore, using access: CollectionsAccess?
    ) -> Task<Bool, Never>? {
        guard take(.rename), let access,
            let current = trips.trips.first(where: { $0.uid == uid })?.title,
            let title = Self.renamed(draft, from: current)
        else { return nil }
        return save {
            try await trips.update(
                uid: uid, patch: TripPatch(title: .set(title)), using: access.handle,
                baseURL: access.baseURL)
        }
    }

    /// Deletes trip `uid` on the server — only when the question was armed and the store holds
    /// the trip. Its photos and memos stay. Claimed here; the returned task is the write.
    @discardableResult
    func confirmDelete(
        _ uid: String, in trips: TripStore, using access: CollectionsAccess?
    ) -> Task<Bool, Never>? {
        guard take(.delete), let access, trips.trips.contains(where: { $0.uid == uid }) else {
            return nil
        }
        return save { try await trips.delete(uid: uid, using: access.handle) }
    }

    /// Makes `picture` trip `uid`'s cover on the server (MEMNG-720).
    @discardableResult
    func setCover(
        _ picture: String, of uid: String, in trips: TripStore, using access: CollectionsAccess?
    ) -> Task<Bool, Never>? {
        guard let access, trips.trips.contains(where: { $0.uid == uid }) else { return nil }
        return save {
            try await trips.update(
                uid: uid, patch: TripPatch(cover: .set(picture)), using: access.handle,
                baseURL: access.baseURL)
        }
    }

    /// Pin or Unpin, named by whether trip `uid` is the scope's active pin at `now`.
    static func pinAction(of uid: String, in trips: TripStore, now: Date) -> TripPinAction {
        trips.pins.activePin(now: now)?.uid == uid ? .unpin : .pin
    }

    /// Pins trip `uid` (until seven days past `lastTaken`, or past `now` without it) or unpins
    /// it. The pin is this device's own: nothing is sent.
    func apply(
        _ action: TripPinAction, to uid: String, in trips: TripStore, lastTaken: Date?, now: Date
    ) {
        guard trips.trips.contains(where: { $0.uid == uid }) else { return }
        switch action {
        case .pin: trips.pin(uid: uid, lastTaken: lastTaken, now: now)
        case .unpin: trips.unpin(uid: uid)
        }
    }

    /// The title a rename files: the draft trimmed, or nil when it is empty or unchanged.
    static func renamed(_ draft: String, from current: String) -> String? {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != current else { return nil }
        return title
    }

    /// What a failed change says: the store's sentence, or nil for one that was superseded (the
    /// account changed while it was out — nothing to say to the new one).
    static func sentence(_ error: any Error) -> String? {
        if let failure = error as? TripStore.Failure { return failure.errorDescription }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func save(
        _ write: @escaping @MainActor () async throws -> Void
    ) -> Task<Bool, Never> {
        saving += 1
        return Task {
            defer { saving -= 1 }
            do {
                try await write()
                failure = nil
                return true
            } catch {
                failure = Self.sentence(error)
                return false
            }
        }
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

/// The members a Trip screen shows: the store's once settled, held while a re-read is on the wire.
struct TripSettledMembers: Equatable {
    var uid: String?
    /// Whose members these are: another account's screen never shows them.
    var identity: TimelineSnapshotIdentity? = nil
    var rows: [LibraryRow] = []
    /// Whether a drain of the trip had applied when these were taken.
    var loaded = false
}
