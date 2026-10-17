import MemosCore
import SwiftUI

/// What the Collections root pushes for a card (MEMNG-817): the collection it opens — a trip, or a
/// tag, a month or a year — known by its id, and whose root it was opened from.
struct CollectionRoute: Hashable {
    /// The collection as it was when its card was opened. A trip's screen draws this once the trip
    /// has left the store, while the stack lets the screen go: a destination that drew nothing for a
    /// trip that is gone would take the screen's own way off the stack with it. An automatic
    /// collection's is all the screen has of the card: its title, count, cover and zone.
    let scope: CollectionScope
    /// The account the card was read under. What the route carries from the card — its cover and
    /// its count — is that account's, and is shown under no other.
    let openedUnder: TimelineSnapshotIdentity?

    init(scope: CollectionScope, openedUnder: TimelineSnapshotIdentity? = nil) {
        self.scope = scope
        self.openedUnder = openedUnder
    }

    init(_ trip: Trip, openedUnder: TimelineSnapshotIdentity? = nil) {
        self.init(scope: .trip(trip), openedUnder: openedUnder)
    }

    var id: String { scope.id }

    /// The trip as it was opened, or nil for an automatic collection.
    var opened: Trip? {
        if case .trip(let trip) = scope { return trip }
        return nil
    }

    static func == (lhs: CollectionRoute, rhs: CollectionRoute) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A collection stands inside the Collections tab (MEMNG-715): the main bar stays under it, with
/// its room at the screen's foot, as under a memo pushed on the Timeline.
extension CollectionRoute: @MainActor StackRoute {
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
/// **Manage.** Rename, Trip Dates, Show Removed and Delete Trip, through `TripManage`, whose
/// writes are the server's (`TripStore.update`/`delete`): while one is out the hero shows it, and
/// a write that failed says why under the title. Trip Dates opens `TripSpanSheet`. A trip that
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
    /// What the screen was opened on (MEMNG-817): a trip as it was when its card was opened, or a
    /// tag, a month or a year. The trip-only chrome — Manage, Trip Dates, Show Removed, Remove from
    /// Trip and Use as Cover — stands only for a trip, because each writes a server collection.
    let scope: CollectionScope
    /// The account the route was opened under: an automatic collection's carried cover and count
    /// are that account's, drawn under no other.
    let openedUnder: TimelineSnapshotIdentity?
    let trips: TripStore
    let memberStore: TripMemberStore
    /// Whose trip this is — the server and the subject; a change reads it again, and lets go of
    /// everything the outgoing account was shown.
    let identity: TimelineSnapshotIdentity?
    /// The session's handle and server when a read is issued, or nil when there is none.
    let access: () -> CollectionsAccess?
    /// The stack this screen was pushed onto, which it leaves once its trip is gone.
    let trail: Binding<[CollectionRoute]>
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
    /// Select mode's Delete and memo actions (MEMNG-788), around the one result banner they share
    /// (`SelectResults`): the toast shows whichever spoke last.
    @State private var results = SelectResults()
    private var deleting: LibraryDeleteFlow { results.deleting }
    /// This screen's claim on the dock while select mode's toolbar stands in the main bar's place.
    @State private var dockClaim = UUID()
    /// The members last shown while they were settled, kept while a re-read is on the wire.
    @State private var settled = TripSettledMembers()
    /// Why the last Remove from Trip did not finish, or nil.
    @State private var removeFailure: String?
    /// What select mode's Remove row asked about (MEMNG-780): the pictures, the trip and the
    /// session, taken when it asked. Only the dialog's Remove sends it; nothing re-reads the
    /// selection after the question.
    @State private var removing: TripPendingRemoval?
    /// Whether that question is on screen; its going away takes it off the screen only.
    @State private var askingRemove = false
    /// Select mode's Set visibility (MEMNG-788): its question and the last run's banner.
    private var acting: MemoActionFlow { results.acting }
    @State private var askingVisibility = false
    @Environment(MemoActionStore.self) private var actions: MemoActionStore?
    /// This showing's lease (`TripMemberStore.coverLease(for:)`): what its lapsed signatures'
    /// re-reads of the carried cover, the members and the journal must still hold.
    @State private var coverLease: TripMemberStore.CoverLease?
    @Namespace private var zoom
    /// What the viewer fetches its stills through; a test hands in one it can watch.
    private let viewerTransport: any MediaTransport
    /// Where select mode's Share fetches the chosen originals; nil for the session's own lane. A
    /// test hands in one it can watch and hold.
    private let shareLane: TripShareLane?
    /// The clock Trip Dates is opened with.
    private let now: () -> Date

    init(
        trip: Trip,
        trips: TripStore,
        memberStore: TripMemberStore,
        identity: TimelineSnapshotIdentity?,
        access: @escaping () -> CollectionsAccess?,
        trail: Binding<[CollectionRoute]> = .constant([]),
        manage: TripManage = TripManage(),
        viewerTransport: any MediaTransport = MediaSession.shared,
        shareLane: TripShareLane? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.init(
            scope: .trip(trip), openedUnder: identity, trips: trips, memberStore: memberStore,
            identity: identity, access: access, trail: trail, manage: manage,
            viewerTransport: viewerTransport, shareLane: shareLane, now: now)
    }

    init(
        scope: CollectionScope,
        openedUnder: TimelineSnapshotIdentity?,
        trips: TripStore,
        memberStore: TripMemberStore,
        identity: TimelineSnapshotIdentity?,
        access: @escaping () -> CollectionsAccess?,
        trail: Binding<[CollectionRoute]> = .constant([]),
        manage: TripManage = TripManage(),
        viewerTransport: any MediaTransport = MediaSession.shared,
        shareLane: TripShareLane? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.scope = scope
        self.openedUnder = openedUnder
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
    /// The filter menu's name and its row that opens the trip's removed pictures (MEMNG-780).
    static let filterButton = "Filter"
    static let removedRowButton = "Removed from trip"
    /// Select mode's Remove row and the dialog it asks (MEMNG-780).
    static func removeRowTitle(_ count: Int) -> String {
        "Remove \(pictures(count)) from trip…"
    }
    static func removeQuestion(_ count: Int, from title: String) -> String {
        "Remove \(pictures(count)) from \(title)?"
    }
    static let removeExplanation = "They stay in your library."
    static let removeConfirmButton = "Remove"
    private static func pictures(_ count: Int) -> String {
        count == 1 ? "1 picture" : "\(count) pictures"
    }
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
        of scope: CollectionScope, in store: TripMemberStore,
        under identity: TimelineSnapshotIdentity?
    ) -> TripSettledMembers? {
        switch store.state(for: scope) {
        case .complete, .truncated:
            TripSettledMembers(
                key: settledKey(scope), identity: identity, rows: store.members(for: scope),
                loaded: store.summary(for: scope) != nil, summary: store.summary(for: scope))
        case .notLoaded, .draining: nil
        }
    }

    /// What kept members are kept under: a trip's uid; an automatic collection's id and zone, since
    /// a month cut in another zone holds other pictures under the same id.
    static func settledKey(_ scope: CollectionScope) -> String {
        switch scope {
        case .trip(let trip): trip.uid
        case .automatic(let collection): "\(collection.id)@\(collection.zone.identifier)"
        }
    }

    /// Of `rows`, read as `scope`'s members, the ones still its members as far as this app knows:
    /// a trip's as the store says (`stillMembers`); an automatic collection's less every picture
    /// Delete took.
    static func stillMembers(
        _ rows: [LibraryRow], of scope: CollectionScope, in store: TripMemberStore
    ) -> [LibraryRow] {
        switch scope {
        case .trip(let trip): return store.stillMembers(rows, of: trip)
        case .automatic:
            guard !store.deleted.isEmpty else { return rows }
            return rows.filter { !store.deleted.contains($0.id) }
        }
    }

    /// What the hero's picture is (MEMNG-817).
    enum HeroCover: Equatable {
        /// A drained member, drawn as a trip's cover is.
        case row(LibraryRow)
        /// The thumbnail the card showed, until the drain answers with that picture.
        case carried(MemoAttachment)
        /// The placeholder.
        case none
    }

    /// A trip's cover as `cover(of:members:)` picks it. An automatic collection's is the drained row
    /// the summary names; while nothing has settled, or while the summary names the card's own
    /// picture without holding it (a drain that stopped short of it), the card's thumbnail — and that
    /// only under the account the card was read for (`carrying`), and as `renewed` once the card's
    /// own signature was renewed (`TripMemberStore.renewCover`).
    static func heroCover(
        _ scope: CollectionScope, summary: TripMemberSummary?, members: [LibraryRow],
        carrying: Bool, renewed: MemoAttachment? = nil
    ) -> HeroCover {
        switch scope {
        case .trip(let trip):
            return cover(of: trip, members: members).map(HeroCover.row) ?? .none
        case .automatic(let collection):
            if let row = summary?.cover { return .row(row) }
            guard carrying, let card = collection.cover, let url = card.thumbnailURL,
                summary == nil || summary?.coverUid == card.uid
            else { return .none }
            if let renewed, renewed.uid == card.uid { return .carried(renewed) }
            return .carried(
                MemoAttachment(
                    uid: card.uid, mime: "image/jpeg", status: .ready, thumbnailURL: url))
        }
    }

    /// The hero's carried thumbnail's identifier when it draws `uid`.
    static func carriedCoverIdentifier(_ uid: String) -> String {
        "collection-carried-cover-\(uid)"
    }

    /// The line under the hero's title: a trip's dates and count, in the device's zone; an
    /// automatic collection's as `CollectionsPresentation.automaticDetail` words it, in the zone its
    /// bucket was counted in, so its span names the days its period holds.
    static func detail(
        _ scope: CollectionScope, summary: TripMemberSummary?, carrying: Bool, locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        switch scope {
        case .trip(let trip):
            CollectionsPresentation.tripDetail(
                trip, summary: summary, locale: locale, timeZone: timeZone)
        case .automatic(let collection):
            CollectionsPresentation.automaticDetail(
                collection, summary: summary, carrying: carrying, locale: locale,
                timeZone: collection.zone)
        }
    }

    /// What an empty grid says.
    static func emptyTitle(for scope: CollectionScope) -> String {
        guard case .automatic(let collection) = scope else { return emptyTitle }
        switch collection.kind {
        case .tag: return "No photos with this tag"
        case .month: return "No photos in this month"
        case .year: return "No photos in this year"
        }
    }

    /// What an empty journal says: a month or a year has no tag, and its journal is the memos
    /// written in it.
    static func journalEmptyTitle(for scope: CollectionScope) -> String {
        guard case .automatic(let collection) = scope else { return journalEmptyTitle }
        switch collection.kind {
        case .tag: return "No memos with this tag"
        case .month: return "No memos in this month"
        case .year: return "No memos in this year"
        }
    }

    /// The space between two cards of one Journal day: the Timeline's own between its cards
    /// (`TimelineView`'s `listRowSpacing`), so a day reads as the Timeline does (MEMNG-820).
    static let journalCardGap = DesignTokens.Space.regular

    /// The cover the hero draws: the chosen one while it is among `members`, else the first.
    static func cover(of trip: Trip, members: [LibraryRow]) -> LibraryRow? {
        trip.cover.flatMap { cover in members.first { $0.id == cover.id } } ?? members.first
    }

    /// The trip this screen was opened on, as it was then; nil for an automatic collection.
    private var openedTrip: Trip? {
        if case .trip(let trip) = scope { return trip }
        return nil
    }

    private var live: Trip? {
        guard let openedTrip else { return nil }
        return trips.trips.first { $0.uid == openedTrip.uid }
    }

    /// What the screen draws: the trip as the store holds it, or as it was on its way out; or the
    /// automatic collection as its card opened it.
    private var shownScope: CollectionScope {
        (live ?? openedTrip).map(CollectionScope.trip) ?? scope
    }

    /// What the reads are keyed on: a trip only while the store holds it — one that is gone is read
    /// no more — and an automatic collection always.
    private var readScope: CollectionScope? {
        scope.isTrip ? live.map(CollectionScope.trip) : scope
    }

    /// Whether the card's own cover and count may be drawn: only under the account it was read for.
    private var carrying: Bool { identity == openedUnder }

    /// Use as Cover writes a server collection: offered on a trip's viewers only.
    private var coverAction: MediaViewerHostAction? {
        scope.isTrip ? Self.useAsCover(scope.id, in: trips, manage: manage, access: access) : nil
    }

    var body: some View {
        // The trip as it was while its screen leaves: a delete takes it out of the store before
        // the stack has popped, and a body that dropped the grid would drop the alert on it in
        // the middle of the alert's own exit — after which the stack never popped.
        let shown = shownScope
        // Read here, in the body, so a drain that lands re-presents the viewer's source as well.
        let fresh = freshMembers(of: shown)
        // What the viewer pages over: the grid's rows, the filtered read's under a filter.
        let paged = viewerRows
        let members = paged.rows
        let loaded = paged.loaded
        modeContent(shown)
            .background(Color(.systemGroupedBackground))
            // On the grid; the rename alert, the file sheet and the viewer's cover each on a view
            // of their own: one presentation per view. An alert rather than a confirmation dialog,
            // for the reason `ComposeView.deleteRow` records: the dialog put its Cancel neither on
            // screen nor in the accessibility tree.
            .alert(Self.deleteQuestion(shown.title), isPresented: asking(.delete)) {
                Button(Self.deleteButton, role: .destructive) {
                    manage.confirmDelete(scope.id, in: trips, using: access())
                }
                Button("Cancel", role: .cancel) { manage.cancel() }
            } message: {
                Text(Self.deleteExplanation)
            }
            .background {
                Color.clear.alert(Self.renameTitle, isPresented: asking(.rename)) {
                    TextField(Self.renameTitle, text: $manage.draft)
                    Button(Self.renameButton) {
                        manage.confirmRename(scope.id, in: trips, using: access())
                    }
                    Button("Cancel", role: .cancel) { manage.cancel() }
                }
            }
            .background { Color.clear.fetchingFile(saving) }
            // Select mode's Remove: an alert, for the delete's reason above.
            .background {
                Color.clear.alert(
                    Self.removeQuestion(
                        removing?.uids.count ?? 0, from: removing?.trip.title ?? shown.title),
                    isPresented: $askingRemove
                ) {
                    Button(Self.removeConfirmButton, role: .destructive) { confirmRemove() }
                    Button("Cancel", role: .cancel) { removing = nil }
                } message: {
                    Text(Self.removeExplanation)
                }
            }
            // Select mode's Set visibility (MEMNG-788): an alert, for the same reason.
            .background {
                Color.clear.alert(
                    MemoActionFlow.question(
                        acting.asking?.memos.count ?? 0, to: acting.asking?.visibility ?? .public),
                    isPresented: $askingVisibility
                ) {
                    Button(MemoActionFlow.confirmTitle) { confirmVisibility() }
                    Button("Cancel", role: .cancel) { acting.cancel() }
                } message: {
                    Text(MemoActionFlow.explanation)
                }
            }
            .background {
                Color.clear.sheet(isPresented: $manage.showingRemoved) {
                    if let removing = live ?? openedTrip {
                        NavigationStack {
                            TripRemovedList(
                                trip: removing, trips: trips, members: memberStore, access: access)
                        }
                    }
                }
            }
            .background {
                Color.clear.sheet(isPresented: $editingSpan) {
                    if let dated = live ?? openedTrip {
                        TripSpanSheet(
                            trip: dated, trips: trips, access: access,
                            lastSummary: memberStore.summary(for: dated), now: now())
                    }
                }
            }
            .navigationTitle(shown.title)
            .navigationBarTitleDisplayMode(.inline)
            // The system bar's (decision B, MEMNG-780): Filter and the ellipsis menu as one group,
            // then Select; in select mode the shared actions menu (`SelectChrome`'s rows) and
            // Close, as plain items the system draws.
            .toolbar {
                if selection.isActive {
                    ToolbarItemGroup(placement: .primaryAction) {
                        let rows = selectRows
                        if !rows.isEmpty {
                            Menu(SelectChrome.moreLabel, systemImage: "ellipsis") {
                                SelectActionRows(rows: rows)
                            }
                        }
                        Button(Self.closeButton, systemImage: "xmark") { selection.close() }
                    }
                } else {
                    if scope.isTrip {
                        ToolbarItemGroup(placement: .primaryAction) {
                            filterMenu
                            manageMenu
                        }
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                    if mode == .photos {
                        ToolbarItem(placement: .primaryAction) {
                            Button(Self.selectButton) { selection.begin() }
                        }
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
                action: coverAction,
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
                removing = nil
                acting.void()
            }
            // A picture that leaves the trip leaves the selection with it.
            // Only against a reading: a filtered read still out is [] and not an answer, so the
            // chosen pictures and the narrowing stand until it lands (review round 2).
            .onChange(of: PruneKey(rows: members.map(\.id), settled: rowsSettled)) { _, key in
                if key.settled { selection.prune(keeping: viewerRows.rows) }
            }
            // A question about the pictures under one filter is no question under another.
            .onChange(of: manage.query) {
                removing = nil
                askingRemove = false
                acting.void()
                askingVisibility = false
            }
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
                let now = viewerRows.rows
                if Self.viewerOutlived(open, holding: held, members: now, loaded: fit.loaded) {
                    viewing = nil
                } else {
                    held = Self.viewerHolds(open, earlier: held, members: now, loaded: fit.loaded)
                }
            }
            .task(
                id: DrainKey(
                    identity: identity, id: scope.id, tag: readScope?.tag, span: readScope?.span)
            ) {
                // The carried cover's lease is taken here too, on every appearance and change of
                // account — in a task, after the change's own handlers, which retire the lease
                // the account held — so it is the one live now; a forget on the way out retires it.
                if !scope.isTrip { coverLease = memberStore.coverLease(for: scope) }
                await drain()
            }
            // The store let the members go — a change to a trip moved its revision — so they are
            // read again; the screen keeps showing the last ones meanwhile.
            .task(id: memberStore.state(for: shown) == .notLoaded) {
                guard memberStore.state(for: shown) == .notLoaded else { return }
                await drain()
            }
            // The grid's filter (MEMNG-780): read again when it changes, the account changes or
            // the store let the read go; the unfiltered query reads nothing of its own.
            .task(
                id: FilterKey(
                    identity: identity, id: scope.id, query: manage.query,
                    stale: filteredState == .notLoaded && !filteredFailed)
            ) {
                await drainFiltered()
            }
            // Read when the chip is chosen, and again whenever it is chosen anew, the account or
            // the tag changes; a load already on the wire is joined.
            .task(
                id: JournalKey(
                    identity: identity, id: scope.id, tag: readScope?.tag, span: readScope?.span,
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
            // A trip's alone: an automatic collection has no record to lose, and stays up through
            // its loading and every refresh of the trips (MEMNG-817).
            .task(id: scope.isTrip && live == nil) {
                guard scope.isTrip, live == nil else { return }
                try? await Task.sleep(for: Self.leavingDelay)
                guard !Task.isCancelled else { return }
                let ids = trips.trips.map(\.uid)
                let kept = CollectionsPresentation.trail(trail.wrappedValue, keeping: ids)
                if kept != trail.wrappedValue { trail.wrappedValue = kept }
            }
            // A tag, a month or a year has no record whose removal would fence its reads, so
            // leaving it is what retires them: a page still on the wire then writes nothing. Only
            // once the stack no longer holds it — a screen pushed over it, or another tab, comes
            // back to it.
            .onDisappear {
                guard !scope.isTrip, !trail.wrappedValue.contains(where: { $0.id == scope.id })
                else { return }
                memberStore.forget(scope)
            }
    }

    /// The chosen mode's content: the grid, the journal, or the map.
    @ViewBuilder
    private func modeContent(_ shown: CollectionScope) -> some View {
        switch mode {
        case .photos: grid(shown)
        case .journal: journal(shown)
        case .map: tripMap(shown)
        }
    }

    /// The trip's members that know where they were taken, on the Places map (MEMNG-719): the
    /// hero above it, so the chips stay in reach. Keyed on the account, so a change of account
    /// drops the map's markers, sheet and viewer with its store (`TripMapScreen`).
    private func tripMap(_ shown: CollectionScope) -> some View {
        TripMapScreen(
            scope: shown, members: memberStore, access: access, redrain: { await drain() },
            viewerAction: coverAction,
            hero: { hero(shown, members: shownMembers.rows) }
        )
        .id(identity)
    }

    /// The trip's memos oldest first, one `MemoCard` each, under a heading per day.
    private func journal(_ shown: CollectionScope) -> some View {
        let memos = memberStore.journal(for: shown)
        let state = memberStore.journalState(for: shown)
        let calendar = journalCalendar(for: shown)
        return List {
            hero(shown, members: shownMembers.rows)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if let error = memberStore.journalError(for: shown) {
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
            if let text = journalFooter(shown, state: state, empty: memos.isEmpty) {
                TripFooter(text: text).cardRow()
            }
        }
        .listStyle(.plain)
        // The Timeline's own gap between cards: a day's cards stood flush without it (MEMNG-820).
        .listRowSpacing(Self.journalCardGap)
        .feedsDock(dock, on: .collections)
        // On the list, not beside the grid's viewer: one presentation per view. Its pages are
        // re-signed by reading the journal again; `memos` is read in the body, so that read
        // re-presents them with its copies.
        .gridViewer(
            $journalViewing, refresher: journalRefresher, zoom: zoom, transport: viewerTransport,
            action: coverAction,
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

    /// The day a memo falls on, in the screen's language: a trip's in the device's zone, a month's
    /// or a year's in the zone its bucket was counted in, so the days head the journal the way
    /// the card counted the period (a tag's zone is the device's, `CollectionsRootView`). A period
    /// holds a memo by when it was written but heads it by its journal instant, its earliest
    /// photograph's (`TripMemberStore.journalInstant(of:)`): a March memo carrying February
    /// photographs stands in March's journal under a February day, which is accepted.
    private func journalCalendar(for shown: CollectionScope) -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        if case .automatic(let collection) = shown { calendar.timeZone = collection.zone }
        calendar.locale = locale
        return calendar
    }

    /// What stands under the last memo: the cap note when the load stopped at the cap, else the
    /// empty line when a load answered with nothing — never over a failure, which says its own.
    private func journalFooter(
        _ shown: CollectionScope, state: TripMemberState, empty: Bool
    ) -> String? {
        // A trip of dates alone has no journal: nothing is read, and the chip says why. A month or
        // a year has no tag either, and its journal is the memos written in it.
        if case .trip(let trip) = shown, trip.tag == nil { return TripMemberStore.noTagJournal }
        if let note = Self.journalCapNote(state, cap: memberStore.memberCap) { return note }
        let read = state == .complete || state == .truncated
        let failed = memberStore.journalError(for: shown) != nil
        return read && empty && !failed ? Self.journalEmptyTitle(for: shown) : nil
    }

    private func grid(_ shown: CollectionScope) -> some View {
        let members = viewerRows.rows
        let items = gridRows
        let state = manage.query.isUnfiltered ? memberStore.state(for: shown) : filteredState
        return LibraryGrid(
            items: items,
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
            // The hero reads the trip's members, never the filtered grid's (its cover included).
            above: AnyView(hero(shown, members: shownMembers.rows)),
            below: footerText(shown, state: state, empty: items.isEmpty).map {
                AnyView(TripFooter(text: $0))
            },
            grouping: .flat
        )
        .environment(\.signedURLRefresher, refresher)
        // The reader's scroll folds and unfolds the main bar, as the Timeline's does: told as the
        // Collections tab's, so it counts only while that tab is on screen (MEMNG-715).
        .feedsDock(dock, on: .collections)
    }

    /// The Photos-style hero (owner, 12:35 CEST 2026-10-14): the cover from edge to edge with the
    /// title and the line under it inside the picture, over the cards' shade; under it the saving
    /// and error lines and the chips.
    private func hero(_ shown: CollectionScope, members: [LibraryRow]) -> some View {
        let summary = heroSummary(shown)
        let detail = Self.detail(
            shown, summary: summary, carrying: carrying, locale: locale, timeZone: timeZone)
        let cover = Self.heroCover(
            shown, summary: summary, members: members, carrying: carrying,
            renewed: Self.carriedUid(of: shown).flatMap { memberStore.renewedCover($0) })
        return VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            heroPicture(
                cover
            )
            // Its own, in every mode: neither the Journal's list nor the Map sets one, and the
            // grid's re-drains members, which a carried picture past the cap is not.
            .environment(\.signedURLRefresher, heroRefresher(for: cover))
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(CollectionCard.shade)],
                    startPoint: .center, endPoint: .bottom
                )
                .accessibilityHidden(true)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: DesignTokens.Space.tight) {
                    Text(shown.title)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DesignTokens.Space.roomy)
                .padding(.bottom, DesignTokens.Space.regular)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
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
            .padding(.horizontal, DesignTokens.Space.roomy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DesignTokens.Space.regular)
    }

    @ViewBuilder
    private func heroPicture(_ cover: HeroCover) -> some View {
        switch cover {
        case .row(let row): TripCover(cover: row)
        case .carried(let attachment): TripCover(carried: attachment)
        case .none: TripCover(cover: nil)
        }
    }

    /// The summary the hero reads: a trip's as the store holds it; an automatic collection's as
    /// last settled under this account, kept while its members are read again.
    private func heroSummary(_ shown: CollectionScope) -> TripMemberSummary? {
        shown.isTrip ? memberStore.summary(for: shown) : shownMembers.summary
    }

    /// What stands under the last picture: the cap note when the drain stopped at the cap, else
    /// the empty line when a drain answered with nothing left — never over a failure, whose
    /// notice is the grid's own.
    private func footerText(_ shown: CollectionScope, state: TripMemberState, empty: Bool)
        -> String?
    {
        if let note = Self.capNote(state, cap: memberStore.memberCap) { return note }
        let drained = state == .complete || state == .truncated
        return drained && empty && memberStore.lastError == nil ? Self.emptyTitle(for: shown) : nil
    }

    /// The one bar at the trip's foot (`AppDock.bar(on:)`). Hosted with no dock — a test that shows
    /// the trip alone — the same rule is asked of select mode's claim alone.
    private var bottomBar: DockBar {
        if let dock { return dock.bar(on: .collections) }
        return DockBar.standing(
            mode: .initial, on: .collections, claim: selection.isActive ? .select : nil)
    }

    /// What a tap of the toolbar acts on: the grid's rows as the store holds them now, the
    /// filtered read's under a filter (`viewerRows`), so a chosen picture past the drain's cap
    /// is still one of them.
    private var currentMembers: [LibraryRow] {
        viewerRows.rows
    }

    /// What the screen shows (`shown`).
    private var shownMembers: TripSettledMembers {
        let shown = shownScope
        return Self.shown(
            shown, fresh: freshMembers(of: shown), settled: settled, identity: identity,
            in: memberStore)
    }

    /// What the screen shows: the store's settled members, else the last settled ones of this
    /// trip and this account while a re-read is on the wire, else none. The ones kept are read
    /// through the store's `stillMembers`, so a removal the server acknowledged, or a Delete,
    /// leaves the screen and the toolbar's reach though no read after it ever lands.
    static func shown(
        _ scope: CollectionScope, fresh: TripSettledMembers?, settled: TripSettledMembers,
        identity: TimelineSnapshotIdentity?, in store: TripMemberStore
    ) -> TripSettledMembers {
        if let fresh { return fresh }
        let key = settledKey(scope)
        guard settled.key == key, settled.identity == identity else {
            return TripSettledMembers(key: key, identity: identity)
        }
        var kept = settled
        kept.rows = stillMembers(settled.rows, of: scope, in: store)
        kept.summary = heldSummary(settled.summary, of: scope, kept: kept.rows, in: store)
        return kept
    }

    /// The summary kept with held members, read again over the ones still kept: an automatic
    /// collection's under the store's own rule
    /// (`TripMemberStore.summary(of:rows:complete:deleted:)`), so a picture Delete took while a re-read is on the wire — or after it failed — leaves the
    /// hero's cover, count and span with its tile. A trip's hero reads the store's summary, not
    /// this one, and nothing deleted leaves it as it was.
    static func heldSummary(
        _ summary: TripMemberSummary?, of scope: CollectionScope, kept rows: [LibraryRow],
        in store: TripMemberStore
    ) -> TripMemberSummary? {
        guard let summary, case .automatic(let collection) = scope, !store.deleted.isEmpty else {
            return summary
        }
        return TripMemberStore.summary(
            of: collection, rows: rows, complete: summary.complete, deleted: store.deleted)
    }

    /// The store's settled members, only while the trip store holds this screen's account: one
    /// that has not moved yet to the account the screen shows still holds the outgoing one's.
    private func freshMembers(of shown: CollectionScope) -> TripSettledMembers? {
        guard identity != nil, trips.identity == identity else { return nil }
        return Self.settled(of: shown, in: memberStore, under: identity)
    }

    /// Select mode's toolbar, the toast of the last delete run over it, and the delete question.
    private var selectBar: some View {
        let members = currentMembers
        return VStack(spacing: DesignTokens.Space.tight) {
            if let message = results.banner.message {
                LibraryDeleteToast(text: message) { results.banner.dismiss() }
            }
            LibrarySelectToolbar(
                count: selection.count,
                ownCount: selection.deletable(in: members).own.count,
                isSharing: sharing.isSharing,
                isDeleting: deleteRunning,
                share: { shareSelection() },
                // Only the chosen pictures that are mine, as in the Library.
                delete: {
                    // No reading under the filter yet: nothing on screen to delete.
                    guard rowsSettled else { return }
                    deleting.claim(LibraryDeleteFlow.tap(selection, in: currentMembers))
                },
                showSelected: { selection.toggleNarrowed() },
                narrowed: selection.narrowed
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
        guard rowsSettled, let lane = shareLane ?? session.map(TripShareLane.session) else {
            return
        }
        let rows = selection.rows(in: currentMembers)
        shareTask = Task {
            _ = await sharing.share(rows, generation: lane.generation, download: lane.download)
        }
    }

    /// Select mode's actions menu: on a trip Set visibility (MEMNG-788), then the destructive
    /// Remove row (MEMNG-780), live while something is chosen and no share or delete is out; none
    /// elsewhere.
    private var selectRows: [SelectAction] {
        guard scope.isTrip else { return [] }
        let free = LibrarySelectionPresentation.actionsEnabled(
            count: selection.count, isSharing: sharing.isSharing, isDeleting: deleteRunning)
        // Under a filter whose read is still out there are no rows to act on.
        let enabled = rowsSettled && free
        let memos = MemoActionPicture.memos(of: chosenPictures)
        let visibilityRows = MemoActionFlow.choices.map { value in
            SelectAction(
                id: "visibility-\(value.rawValue)", title: value.label,
                systemImage: value == .public ? "globe" : "person.2"
            ) { askVisibility(value) }
        }
        return [
            SelectAction(
                id: "visibility", title: MemoActionFlow.visibilityRowTitle(memos.count),
                systemImage: "eye", disabled: !enabled || actions == nil || memos.isEmpty,
                children: visibilityRows),
            SelectAction(
                id: "remove", title: Self.removeRowTitle(selection.count),
                systemImage: "minus.circle", role: .destructive, disabled: !enabled
            ) { askRemove() },
        ]
    }

    /// The chosen pictures as the memo actions see them, in the order chosen.
    private var chosenPictures: [MemoActionPicture] {
        selection.rows(in: currentMembers).map(MemoActionPicture.init)
    }

    /// Public or Just us (MEMNG-788): the question is asked about the memos chosen NOW, under
    /// this session and this filter (`MemoActionFlow.ask`).
    private func askVisibility(_ visibility: MemoVisibility) {
        guard rowsSettled, let access = access() else { return }
        acting.ask(
            memos: MemoActionPicture.memos(of: chosenPictures), visibility: visibility,
            generation: access.handle.generation, filter: "\(manage.query)")
        askingVisibility = acting.asking != nil
    }

    /// The question's Change, claimed synchronously; the members and the filtered read are read
    /// again after the run, which let them go (`TripStore.membersChanged`).
    private func confirmVisibility() {
        guard let actions, let access = access(),
            let asked = acting.claim(
                generation: access.handle.generation, filter: "\(manage.query)")
        else {
            acting.cancel()
            return
        }
        Task {
            await acting.perform(
                issuedUnder: access.handle.generation,
                current: { self.access()?.handle.generation },
                rereads: [{ await drain(using: access) }, { await drainFiltered(using: access) }]
            ) {
                await actions.setVisibility(
                    asked.visibility, forMemos: asked.memos, using: access.handle,
                    baseURL: access.baseURL)
            }
        }
    }

    /// The Remove row: the question is asked about the pictures chosen NOW, the trip and the
    /// session — what the answer sends, whatever the selection does meanwhile.
    private func askRemove() {
        let chosen = selection.rows(in: currentMembers).map(\.id)
        guard rowsSettled, !chosen.isEmpty, let access = access(), let target = live ?? openedTrip
        else { return }
        removing = TripPendingRemoval(
            uids: chosen, trip: target, access: access, query: manage.query)
        askingRemove = true
    }

    /// The dialog's Remove: the question is claimed here, synchronously, so a second answer finds
    /// none; the chosen pictures leave this trip, and the selection with them — select mode
    /// stays, holding nothing, as after a Delete.
    private func confirmRemove() {
        guard let asked = removing else { return }
        removing = nil
        // Asked under one session, answered under another: the question was about pictures the
        // session now on screen never chose, so nothing is sent.
        guard let now = access(), now.handle.generation == asked.access.handle.generation else {
            return
        }
        // Asked under one filter, answered under another: the grid no longer shows what it
        // asked about, so nothing is sent either.
        guard manage.query == asked.query else { return }
        Task {
            do {
                let outcome = try await memberStore.remove(
                    asked.uids, from: asked.trip, using: asked.access.handle,
                    baseURL: asked.access.baseURL)
                removeFailure = outcome.stopped.flatMap(TripManage.sentence)
            } catch {
                removeFailure = TripManage.sentence(error)
            }
            // Against a reading only: a filtered read the removal let go is no empty answer.
            if rowsSettled { selection.prune(keeping: currentMembers) }
        }
    }

    /// Select mode ended: a share still fetching stops being the live one and its task is
    /// cancelled, an open question closes, and the dock is given back.
    private func endSelect() {
        sharing.abandon()
        shareTask?.cancel()
        shareTask = nil
        deleting.abandon()
        acting.abandon()
        removing = nil
        dock?.release(dockClaim)
    }

    /// The filter menu (MEMNG-780): the Library's kinds and Sort By, read by the server, then the
    /// row that opens the removed pictures.
    private var filterMenu: some View {
        Menu(Self.filterButton, systemImage: LibraryFilterMenuContent.symbol) {
            TripFilterMenuContent(query: $manage.query) { manage.showRemoved() }
        }
    }

    /// The ellipsis menu: Rename, Trip Dates, then Delete Trip.
    private var manageMenu: some View {
        Menu(Self.manageButton, systemImage: "ellipsis") {
            Button(Self.renameButton, systemImage: "pencil") {
                manage.askRename(current: shownScope.title)
            }
            Button(Self.spanButton, systemImage: "calendar") { editingSpan = true }
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
            scope: scope,
            session: IssuingSession(handle: { access()?.handle }, baseURL: { access()?.baseURL }),
            lease: coverLease,
            query: manage.query
        )
    }

    /// Who re-signs the hero's picture: a drained member by the trip's read again, the card's carried
    /// picture by a read of that picture alone.
    private func heroRefresher(for cover: HeroCover) -> (any SignedURLRefreshing)? {
        switch cover {
        case .row: return refresher
        case .carried:
            guard let coverLease else { return nil }
            let access = access
            return CarriedCoverURLRefresher(
                members: memberStore,
                session: IssuingSession(
                    handle: { access()?.handle }, baseURL: { access()?.baseURL }),
                lease: coverLease)
        case .none: return nil
        }
    }

    /// The picture an automatic collection's card carried; nil for a trip.
    static func carriedUid(of scope: CollectionScope) -> String? {
        guard case .automatic(let collection) = scope else { return nil }
        return collection.cover?.uid
    }

    /// Who re-signs a lapsed picture of the Journal: a read of the journal again.
    private var journalRefresher: TripJournalURLRefresher {
        let access = access
        return TripJournalURLRefresher(
            members: memberStore,
            trips: trips,
            scope: scope,
            session: IssuingSession(handle: { access()?.handle }, baseURL: { access()?.baseURL }),
            lease: coverLease
        )
    }

    /// The members' read, under `given` — a memo action's issuing session — or the session now.
    private func drain(using given: CollectionsAccess? = nil) async {
        guard let readScope, let access = given ?? access() else { return }
        await memberStore.drain(readScope, using: access.handle, baseURL: access.baseURL)
    }

    /// The grid's filtered read of the trip, or the retirement of one for the unfiltered query,
    /// under `given` — a memo action's issuing session — or the session now.
    private func drainFiltered(using given: CollectionsAccess? = nil) async {
        guard let trip = live ?? openedTrip, let access = given ?? access() else { return }
        await memberStore.drainFiltered(
            trip, query: manage.query, using: access.handle, baseURL: access.baseURL)
    }

    /// Where the grid's filtered read stands; a collection that is no trip has none.
    private var filteredState: TripMemberState {
        guard let trip = live ?? openedTrip else { return .notLoaded }
        return memberStore.filteredState(for: trip, query: manage.query)
    }

    /// Whether the grid's filtered read failed and nothing has asked again: no re-read by itself.
    private var filteredFailed: Bool {
        guard let trip = live ?? openedTrip else { return false }
        return memberStore.filteredFailed(for: trip, query: manage.query)
    }

    /// What the grid draws: `viewerRows`, narrowed to the chosen pictures while Show Selected is
    /// pressed.
    private var gridRows: [LibraryRow] {
        selection.visible(in: viewerRows.rows)
    }

    /// Whether `viewerRows` is a reading: unfiltered, once a drain has settled — drained whole,
    /// not pages still arriving (`settled(of:in:under:)` holds members only at `.complete` or
    /// `.truncated`) — and under a filter once its read of the current lineage has landed. Until
    /// then nothing is pruned against it and no action acts on it.
    private var rowsSettled: Bool { viewerRows.loaded }

    /// The grid's rows before Show Selected narrows them — the members, or the trip's filtered
    /// read while a filter is chosen — and whether they are a reading: what a tap opens the
    /// viewer over and pages through, and what the selection is kept within. Under a filter a
    /// picture of the filtered read is there even when the capped drain never reached it.
    private var viewerRows: (rows: [LibraryRow], loaded: Bool) {
        guard !manage.query.isUnfiltered, let trip = live ?? openedTrip else {
            let current = shownMembers
            return (current.rows, current.loaded)
        }
        let filtered = memberStore.filteredMembers(for: trip, query: manage.query)
        return (filtered ?? [], filtered != nil)
    }

    private func loadJournal() async {
        guard let readScope, let access = access() else { return }
        await memberStore.loadJournal(readScope, using: access.handle, baseURL: access.baseURL)
    }

    /// What the selection is pruned against, and whether it is a reading at all.
    private struct PruneKey: Equatable {
        let rows: [String]
        let settled: Bool
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

    private struct FilterKey: Equatable {
        let identity: TimelineSnapshotIdentity?
        let id: String
        let query: TripMemberQuery
        let stale: Bool
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
    /// The thumbnail an automatic collection's card carried, drawn while no drained row stands in
    /// for it (MEMNG-817).
    var carried: MemoAttachment? = nil

    static let height: CGFloat = 240

    init(cover: LibraryRow?) { self.cover = cover }

    init(carried: MemoAttachment) {
        cover = nil
        self.carried = carried
    }

    /// The width the cover is laid out at: a thumbnail's slot fits its ratio inside the frame, so
    /// a fixed 4:3 drew a 320-point picture centred in a 402-point hero.
    @State private var width: CGFloat = 0

    /// The frame's own ratio, so a fill reaches both edges.
    private var slot: AttachmentSlot {
        AttachmentSlot(aspectRatio: max(width, 1) / Self.height, contentMode: .fill)
    }

    var body: some View {
        Group {
            if let carried {
                AttachmentThumbnail(
                    attachment: carried,
                    tier: .thumb,
                    slot: slot,
                    cornerRadius: 0
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TripView.coverLabel)
                .accessibilityIdentifier(TripView.carriedCoverIdentifier(carried.uid))
            } else if let cover {
                AttachmentThumbnail(
                    attachment: cover.attachment,
                    tier: .mobile,
                    slot: slot,
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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { measured in
            width = measured
        }
        // Edge to edge, as Photos draws a collection's cover: no corner to round.
        .clipped()
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
    /// The filter menu's Removed from trip sheet is up.
    var showingRemoved = false
    /// The grid's Kind and Sort (MEMNG-780): the filter menu's choice, read by the server.
    var query = TripMemberQuery.unfiltered

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
    /// Whose members these are (`TripView.settledKey`).
    var key: String?
    /// Whose members these are: another account's screen never shows them.
    var identity: TimelineSnapshotIdentity? = nil
    var rows: [LibraryRow] = []
    /// Whether a drain of the trip had applied when these were taken.
    var loaded = false
    /// The summary read with these members, kept with them.
    var summary: TripMemberSummary? = nil
}

/// The question select mode's Remove row asked (MEMNG-780): what the dialog's Remove sends — the
/// pictures chosen when it asked, the trip, and the session it asked under.
struct TripPendingRemoval {
    let uids: [String]
    let trip: Trip
    let access: CollectionsAccess
    /// The grid's filter when it asked: an answer under another one sends nothing.
    let query: TripMemberQuery
}

/// The trip's filter menu (MEMNG-780): the Library's own filter rows (`MediaFilterRows` — the
/// kinds, "Captured by me" and Visibility, MEMNG-787), a divider, its nested Sort By menu — the
/// same rows and glyphs as `LibraryFilterMenuContent` — then, after a divider, the row that opens
/// the pictures removed from the trip.
struct TripFilterMenuContent: View {
    @Binding var query: TripMemberQuery
    let showRemoved: () -> Void

    var body: some View {
        MediaFilterRows(
            filter: $query.filter, mine: $query.mine, visibility: $query.visibility)
        Divider()
        SortByMenu(order: $query.order)
        Divider()
        // Offered before anything is known: its sheet computes the list when it opens.
        Button(TripView.removedRowButton, systemImage: "eye.slash", action: showRemoved)
    }
}
