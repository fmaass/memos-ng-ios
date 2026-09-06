import MemosCore
import MemosOutbox
import SwiftUI

/// Where a memo is going when the card is tapped. A route rather than a `NavigationLink` in the
/// row is what removes the chevron: a link inside a list row draws one, and the chevron was the
/// only thing that looked tappable on a card whose photos were not.
struct MemoRoute: Hashable {
    let uid: String
}

/// The timeline: one cursor-paginated page at a time, pull to refresh — and, since Phase 4,
/// the place memos are made and managed.
///
/// The list is grouped by day and built out of cards. Days come from `TimelineGrouping`, which
/// regroups the whole loaded list rather than the page that just arrived, because a day routinely
/// straddles a cursor boundary and would otherwise get its header printed twice.
public struct TimelineView: View {
    @Environment(SessionStore.self) private var session
    // Optional: a preview or a test host has no outbox, and a missing environment value must not
    // be a crash on the app's main screen.
    @Environment(Outbox.self) private var outbox: Outbox?
    @Environment(\.scenePhase) private var scenePhase
    /// A memo the Library asked this tab to open. Optional for the same reason the outbox is: a
    /// preview or a test host has no router.
    @Environment(MemoJump.self) private var jump: MemoJump?
    @State private var timeline: TimelineStore?
    /// A memo read from the server because a jump named one this list has never loaded. It is what
    /// the detail screen opens WITH — the loaded list is left alone, so nothing is inserted into a
    /// timeline nobody scrolled to (MEMNG-191).
    @State private var jumped: Memo?
    /// Why a jump from the Library ended on this screen with nothing opening.
    @State private var jumpNotice: String?
    /// Whether the list has been away from its top since the last time it was there — the whole
    /// of the upward-paging trigger, kept as a value so the sequence can be asserted
    /// (`TimelineTopWatch`).
    @State private var topWatch = TimelineTopWatch()
    /// The row the reader was standing on when a block of newer memos went above it, and the
    /// trigger that puts them back on it. A counter for the same reason `jumps` is one: two
    /// prepends can restore to the same row, and a plain `onChange` of the uid would see no
    /// change at all the second time.
    @State private var restoreTop: String?
    @State private var restores = 0

    /// How many times this screen has been taken to a day. It is a trigger, not a count: a jump
    /// replaces the whole list, and the scroll it was read at belongs to a list that is gone.
    @State private var jumps = 0
    @State private var composing: ComposeView.Mode?
    /// One conversation for the whole screen, shared with the Settings screen pushed from it —
    /// two stages would be two machines and, between them, two revokes.
    @State private var signOut = SignOutConversation()
    /// The account's picture, decoded once here and handed to Settings.
    @State private var avatar: Image?
    /// Type-erased because the stack now leads to two different places: a memo, and Settings.
    @State private var path = NavigationPath()
    @State private var feedback = MemoFeedbackTrigger()
    /// The media a tile tap opened, full screen. A tapped video opens it too — on the video's
    /// own page, already playing — so the rest of the memo stays one swipe away.
    @State private var viewing: MediaViewerSelection?
    /// What the zoom transition matches the viewer to: the tile it grew out of.
    @Namespace private var mediaZoom
    /// The search the loupe raised, its sheet, and the list it fills. Built fresh at every tap —
    /// a term left over from last time is a filter silently hiding memos, which is the worse
    /// failure (design note §5, Q4) — and kept here rather than inside the sheet because the
    /// results screen the sheet pushes outlives the sheet.
    ///
    /// ONE object rather than a store beside a boolean. A sheet raised by a boolean draws whatever
    /// its content closure can see when the presentation begins, and a content gated on a separate
    /// optional draws nothing at all if that optional has not landed — a blank sheet with no
    /// `.task` on it to load anything either, right until it is closed and opened again
    /// (MEMNG-175). `SearchPresentation` carries the store in the item the sheet is raised FROM,
    /// so the two cannot be out of step.
    @State private var searchPresentation = SearchPresentation()
    /// Set only for the one sheet close that is a hand-off to the results screen rather than
    /// an abandonment, so `dismissSearch` knows not to reset the store the results screen has
    /// just adopted.
    @State private var handingOff = false

    public init() {}

    public var body: some View {
        // The sheet is raised from an ITEM, and an item needs a binding into the presentation
        // rather than to it.
        @Bindable var presentation = searchPresentation
        return NavigationStack(path: $path) {
            Group {
                if let timeline {
                    content(timeline)
                } else {
                    ProgressView()
                }
            }
            .background(Color(.systemGroupedBackground))
            // No large title. The app's own name over its only screen told nobody anything, and a
            // large title spends a whole band of the screen before the first memo — on the surface
            // where the content is the point. The toolbar keeps both its controls exactly where
            // they were, and the day headings become what the top of the scroll reads as, which is
            // what they already looked like they were.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // `stackDestination`, not `navigationDestination`: what the tab bar does under a
            // pushed screen is the route's to say, and saying it here is how Settings came to be
            // drawn under the Timeline and Library icons it has nothing to do with (MEMNG-220).
            .stackDestination(for: SettingsRoute.self) { _ in
                SettingsView(signOut: signOut, avatar: avatar)
            }
            // The memo is looked for in BOTH lists. A card tapped on the search results is a
            // memo the home timeline has very often never loaded, and a destination that only
            // knew the timeline pushed an empty screen for exactly those memos. Whichever list
            // held it is also the list the detail screen edits, so an edit made from a result
            // lands where it was read.
            .stackDestination(for: MemoRoute.self) { route in
                if let found = holder(of: route.uid) {
                    MemoDetailView(uid: route.uid, initial: found.memo, timeline: found.store)
                }
            }
            .navigationDestination(for: SearchResultsRoute.self) { _ in
                if let search = searchPresentation.search {
                    SearchResultsView(
                        search: search,
                        mediaZoom: mediaZoom,
                        openMemo: { path.append(MemoRoute(uid: $0)) },
                        openAttachment: { open($0, of: $1) }
                    )
                }
            }
            // Top-LEFT is the account's own face; top-RIGHT is the search loupe and then New
            // memo, which stays rightmost. Which is which is decided in `TimelineToolbar` rather
            // than here — a placement written inline in a screen that needs a live session to
            // construct is one no test can read back.
            //
            // This screen's job is only to say what the bar is showing and what its controls do.
            .toolbar {
                TimelineToolbar(
                    composed: feedback.count,
                    openSettings: { path.append(SettingsRoute()) },
                    search: { openSearch() },
                    newMemo: { composing = .create }
                )
            }
            // Attached HERE, inside the stack, and not out on the chain that carries the compose
            // sheet and the viewer: two presentations on one view is how one of them silently
            // stops appearing, which is the reason the cover was moved out in the first place.
            // `onDismiss` is bound so EVERY close funnels through one place — Done, the
            // hand-off to the results screen, and an interactive swipe the app never hears
            // about otherwise. A debounced or in-flight search that outlived the sheet would
            // otherwise write its result into a model nobody is looking at.
            .sheet(item: $presentation.session, onDismiss: dismissSearch) { raised in
                SearchSheet(
                    search: raised.search,
                    loadHeatmap: { store in
                        guard let handle = session.activeHandle else { return }
                        // Named before the read, so a failure that never reached the server lands
                        // in the session's one banner instead of on this card.
                        store.reports(to: session)
                        await store.load(using: handle)
                    },
                    chose: { choice in
                        jump(to: choice.anchor)
                        // The commit row is the sheet's one verb (MEMNG-187): the day is settled,
                        // so the sheet goes and what is left on screen is the anchored list with
                        // the notice on top of it naming the day. A scrub or a picked date is a
                        // field being moved, and the sheet stays for the next correction. Which
                        // of the two it is, is `SearchPresentation.chose` — decided where the
                        // presentation lives, so it is a decision a test can drive.
                        searchPresentation.chose(choice)
                    },
                    loadTags: { store in
                        guard let handle = session.activeHandle else { return }
                        store.reports(to: session)
                        await store.load(using: handle)
                    },
                    runSearch: { query, text in raised.search.run(query, showing: text) },
                    close: { searchPresentation.close() },
                    showResults: {
                        handingOff = true
                        searchPresentation.close()
                        path.append(SearchResultsRoute())
                        // The depth it now sits at, so the live channel can tell a list somebody
                        // is reading from one that is merely still in memory.
                        searchPresentation.resultsPushed(atDepth: path.count)
                    }
                )
            }
        }
        // On the navigation stack rather than further down the chain, so it is a different view
        // from the one presenting the compose sheet — two presentations on one view is how one of
        // them silently stops appearing.
        .fullScreenCover(item: $viewing) { selection in
            // A memo's media is all there when the card is drawn and never grows, so the viewer
            // over it pages through a value rather than through a store.
            MediaViewerView(selection: selection, source: .fixed(selection.pages))
                .mediaZoomTransition(sourceID: selection.id, in: mediaZoom)
        }
        .tint(DesignTokens.accent)
        .sensoryFeedback(trigger: feedback) { _, latest in latest.act?.feedback }
        .sheet(item: $composing) { mode in
            if let timeline {
                ComposeView(mode: mode) { submission in
                    await submit(mode, submission: submission, to: timeline)
                }
            }
        }
        .signOutAlerts(signOut, session: session)
        // Decoded once, here, because the toolbar shows it on every frame of the timeline and the
        // Settings screen shows it again — one decode, handed to both.
        .task(id: session.avatar) { avatar = await AccountAvatar.image(from: session.avatar) }
        // The foreground trigger, and one of only two the re-validation has. `initial: true`
        // because a timeline created while the app is ALREADY active never sees a change — which
        // is every launch — and the session's single-flight absorbs the overlap with the launch
        // check this joins.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: Task { await session.enteredForeground() }
            case .background, .inactive: session.enteredBackground()
            @unknown default: break
            }
        }
        .task {
            if timeline == nil {
                let store = TimelineStore(
                    // Every day this screen can be anchored at is a day the heatmap named, and
                    // the heatmap's days are the server's UTC ones — see
                    // `HeatmapDateJump.anchorCalendar` for what reading them in the device's zone
                    // would hide.
                    calendar: HeatmapDateJump.anchorCalendar,
                    snapshots: session.snapshots,
                    snapshotIdentity: snapshotIdentity,
                    // The one list in the app that is worth opening on tomorrow.
                    persists: true,
                    onUnauthorized: { [session] in
                        await session.handle(.unauthorized)
                    }
                )
                // Before anything is read off the disk: a store that persists reads the session's
                // incarnation through this seam, and a picture stamped before it was named would
                // carry a number belonging to nobody.
                store.reports(to: session)
                // Published BEFORE the read, not after it: the read is an await, and the
                // withdrawal below reaches this store through `timeline`. Assigned afterwards,
                // an account switch during the read would have nothing to tell.
                timeline = store
                // Before `load()`, and that order is the feature: the rows this phone last saw go
                // on screen while the request that will replace them is still out — or never
                // answers at all.
                await store.restoreSnapshot()
            }
            // A failure that never reached the server belongs to the session's one banner, not to
            // an error card over this list (`SessionReporting`).
            timeline?.reports(to: session)
            await load()
            // What "Default" resolves to is the account's setting, not something the app can
            // guess. It is fetched here rather than during sign-in so a slow or missing
            // /api/settings can never hold up getting someone into the app.
            await session.loadSettings()
            // Adopt whatever the last run left in flight before anything new is scheduled.
            await outbox?.start()
        }
        // A snapshot on screen belongs to the identity that wrote it. If the session becomes
        // somebody else's — or nobody's — while it is up, it goes; a list the server has since
        // sent is left alone.
        .onChange(of: session.state.user?.subject) {
            timeline?.sessionIdentityChanged(to: snapshotIdentity)
        }
        // The live media channel, and its single owner.
        //
        // One channel for the whole signed-in app: this view is the app's first tab, so it exists
        // for exactly as long as there is a session (a tab switch does not tear it down), and it
        // holds the store every event is applied to — so a memo's own screen, pushed over this
        // one, needs no channel of its own the way it once needed a poll of its own.
        //
        // Attached to the NAVIGATION STACK, not to the timeline inside it. A view inside the stack
        // is the thing a push covers, and whether covering it cancels its `.task` is a detail of
        // SwiftUI's version rather than of this app. Out here the question does not arise: nothing
        // a push does to the root's content reaches this modifier, so the channel's lifetime is
        // the screen's, which is what it is supposed to be.
        //
        // Keyed on the DECISION, so SwiftUI's own cancellation is the mechanism: the decision
        // going false IS the teardown, and its going true again — foregrounded, signed in, and the
        // store now built by the task above — IS the restart.
        .task(id: mediaChannelRuns) { await runMediaChannel() }
        // Every way back out of the results — Back, an interactive swipe, a pop to the root —
        // shows up here as the stack getting shallower, which is the only signal any of them
        // share. `stackChanged` decides what that means for the results screen; it is a depth
        // and not an appearance for the reason `resultsDepth` gives.
        .onChange(of: path.count) { _, depth in
            searchPresentation.stackChanged(toDepth: depth)
        }
        // A capture that leaves the queue has become a memo on the server; the list it belongs in
        // is reloaded so it does not appear to have vanished.
        .onChange(of: outbox?.lastCompletedAt) { _, _ in
            Task { await load() }
        }
        // A memo asked for from the Library. Keyed on the request rather than run from an
        // `onChange`, because satisfying it can mean reading the memo from the server first and
        // that read must be cancellable with the screen.
        .task(id: jump?.pending) { await consumeJump() }
    }

    /// Opens the memo a jump named, reading it first when this list has never loaded it.
    ///
    /// The read is not optional and not an optimisation. A photograph a few screens into the
    /// library routinely belongs to a memo a hundred cursor pages down this list, and
    /// `TimelineStore.apply` — which `refreshMemo` goes through — DISCARDS a memo the list does not
    /// hold. So the memo is fetched and carried to the detail screen as its `initial`, which is
    /// exactly what that screen falls back to when the list has no copy of its own.
    private func consumeJump() async {
        guard let jump, let uid = jump.pending, let timeline else { return }
        // Cleared on every path: a request nobody can satisfy must not sit pending and re-fire.
        defer { jump.clear() }
        // A new jump is a new answer; last time's notice is not this jump's.
        jumpNotice = nil
        switch MemoJumpRouting.resolution(uid: uid, loaded: timeline.memos.map(\.uid)) {
        case .push:
            path.append(MemoRoute(uid: uid))
        case .fetchThenPush:
            guard let handle = session.activeHandle, let baseURL = session.serverBaseURL
            else { return }
            let outcome = await timeline.jump(
                to: uid,
                calendar: HeatmapDateJump.anchorCalendar,
                using: handle,
                baseURL: baseURL
            )
            switch outcome {
            case .ready(let memo):
                // The store now HOLDS it, so the screen about to open edits through this list. The
                // fetched value is only what the push opens WITH, for the instant before the row
                // is read out of `memos`.
                jumped = memo
                // The list came back anchored at that memo's day, which is a different list from
                // the one that was on screen — the same landing a day chosen on the heatmap gets.
                topWatch.settled()
                restoreTop = nil
                jumps += 1
                path.append(MemoRoute(uid: uid))
            case .unavailable:
                // Switching tabs and then doing nothing reads as the app losing the tap. Say what
                // happened instead: the memo is gone, or it is not in the list this screen shows.
                jumpNotice = "That memo is no longer here."
            }
        }
    }

    /// The screen's scroll, and the one thing that moves it on its own.
    @ViewBuilder
    private func content(_ timeline: TimelineStore) -> some View {
        ScrollViewReader { proxy in
            list(timeline)
                // The list a jump produced starts at the anchored day, so the top of it IS that
                // day — this puts the reader there rather than wherever the old list had been
                // scrolled to. It is one call on purpose: scrolling INTO a day the server has not
                // sent yet would be a paging engine, and the anchored request is what makes one
                // unnecessary.
                .onChange(of: jumps) { _, _ in
                    withAnimation(.snappy) {
                        proxy.scrollTo(Self.jumpTop, anchor: .top)
                    } completion: {
                        // This scroll passes through "away from the top" on its way to the top.
                        // Left unsaid, its arrival would read as a reader scrolling back up and
                        // would page the memos they just jumped away from straight back on.
                        topWatch.settled()
                    }
                }
                // A list that grew upwards under a still finger has carried the reader down the
                // page by exactly as much as it grew. Unanimated on purpose: the reader did not
                // move, so nothing should appear to.
                .onChange(of: restores) { _, _ in
                    guard let restoreTop else { return }
                    proxy.scrollTo(restoreTop, anchor: .top)
                }
                // An anchored list has memos above it, and until MEMNG-179 nothing in this app
                // could ask for them: the cursor only ever descends. Arriving at the top is what
                // asks now — an arrival, not a top row appearing, for the reason `TimelineTopWatch`
                // gives.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    TimelineTopWatch.isAtTop(
                        contentOffsetY: geometry.contentOffset.y,
                        topInset: geometry.contentInsets.top
                    )
                } action: { _, atTop in
                    guard topWatch.arrivedAtTop(atTop) else { return }
                    Task { await loadNewer(in: timeline) }
                }
        }
    }

    /// The row a jump scrolls to: the notice that says which day the list was taken to, which is
    /// the first thing in an anchored list.
    private static let jumpTop = "timeline-jump-top"

    @ViewBuilder
    private func list(_ timeline: TimelineStore) -> some View {
        // The flat position of each memo, so the prefetch trigger still knows how close to the
        // end of the LIST a row is once the list has been cut into days.
        let positions = Dictionary(
            uniqueKeysWithValues: timeline.memos.enumerated().map { ($1.uid, $0) }
        )
        List {
            // Why this list is not the one that was here a moment ago, and the way back to now.
            if let anchor = timeline.query.anchor {
                TimelineAnchorNotice(
                    title: HeatmapDateJump.title(for: anchor),
                    clear: clearAnchor
                )
                .cardRow()
                .id(Self.jumpTop)
            }
            if let outbox, !outbox.jobs.isEmpty {
                Section {
                    ForEach(PendingMemoPresentation.rows(for: outbox.jobs)) { row in
                        PendingCard(
                            row: row,
                            retry: { Task { await outbox.retry(row.id) } },
                            remove: { Task { await outbox.discard(row.id) } }
                        )
                        .cardRow()
                    }
                } header: {
                    SectionHeading(title: "Pending")
                }
            }
            // Session-level notices (a credential that could not be saved, a failed revoke)
            // must survive into the signed-in surface — a warning nobody can see is not one.
            if let notice = session.lastError {
                NoticeCard(text: notice, tone: .warning).cardRow()
            }
            if let error = timeline.lastError {
                NoticeCard(text: error, tone: .error).cardRow()
            }
            // A jump that arrived from the Library and had nowhere to land.
            if let jumpNotice {
                NoticeCard(text: jumpNotice, tone: .warning).cardRow()
            }
            // A capture the outbox REFUSED never becomes a pending row, so this is the only place
            // it can be seen at all. Without it, Post closed nothing, queued nothing, sent nothing
            // and said nothing — which is what "writing a memo does not work" looked like.
            if let error = outbox?.lastError {
                NoticeCard(text: error, tone: .error).cardRow()
            }
            ForEach(TimelineGrouping.sections(for: timeline.memos)) { section in
                Section {
                    ForEach(section.memos) { memo in
                        // Not a card-wide Button any more: the photos have their own destination,
                        // so the card routes a tap by where it landed (MemoCardTap) — tile to the
                        // full-screen viewer, anywhere else to the memo.
                        MemoCard(
                            memo: memo,
                            mediaZoom: mediaZoom,
                            openMemo: { path.append(MemoRoute(uid: memo.uid)) },
                            openAttachment: { open($0, of: memo) }
                        )
                        .cardRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if memo.mine {
                                Button(role: .destructive) {
                                    Task { await delete(memo, in: timeline) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if memo.mine {
                                Button {
                                    Task { await setPinned(!memo.pinned, on: memo, in: timeline) }
                                } label: {
                                    Label(
                                        memo.pinned ? "Unpin" : "Pin",
                                        systemImage: memo.pinned ? "pin.slash" : "pin"
                                    )
                                }
                                .tint(DesignTokens.accent)
                            }
                        }
                        .contextMenu {
                            if memo.mine {
                                Button {
                                    composing = .edit(
                                        uid: memo.uid,
                                        content: memo.content,
                                        createdAt: memo.createdAt
                                    )
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                visibilityMenu(for: memo, in: timeline)
                            }
                        }
                        .task {
                            guard let index = positions[memo.uid],
                                timeline.shouldLoadMore(after: index)
                            else { return }
                            guard let handle = session.activeHandle,
                                let baseURL = session.serverBaseURL
                            else { return }
                            await timeline.loadMore(using: handle, baseURL: baseURL)
                        }
                    }
                } header: {
                    SectionHeading(title: TimelineGrouping.title(for: section.day))
                }
            }
            if timeline.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .cardRow()
            }
        }
        .listStyle(.plain)
        .listRowSpacing(DesignTokens.Space.regular)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await load() }
        .overlay {
            // A queued capture is not "no memos yet" — the empty state must not paint over the
            // one thing a person is waiting on.
            if timeline.memos.isEmpty && !timeline.isLoading && (outbox?.jobs.isEmpty ?? true) {
                ContentUnavailableView("No memos yet", systemImage: "note.text")
            }
        }
    }

    @ViewBuilder
    private func visibilityMenu(for memo: Memo, in timeline: TimelineStore) -> some View {
        Menu {
            ForEach(MemoVisibility.allCases, id: \.self) { option in
                Button {
                    Task {
                        guard let handle = session.activeHandle,
                            let baseURL = session.serverBaseURL
                        else { return }
                        await timeline.setVisibility(
                            option, uid: memo.uid, using: handle, baseURL: baseURL
                        )
                    }
                } label: {
                    if memo.visibility == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Label(option.label, systemImage: option.symbolName)
                    }
                }
            }
        } label: {
            Label("Visibility", systemImage: "eye")
        }
    }

    private func memo(_ uid: String, in timeline: TimelineStore) -> Memo? {
        timeline.memos.first { $0.uid == uid }
    }

    /// The list a memo was read from, and the memo. The timeline first: it is the canonical list,
    /// and a memo in both is the same memo.
    ///
    /// The third case is a memo in NEITHER list: one reached by a jump from the Library, read from
    /// the server for exactly this push. It is last because it is the only copy that is not part of
    /// a list anything else is reading — the detail screen still edits through the timeline store,
    /// and this value only stands in until that store has one of its own.
    private func holder(of uid: String) -> (memo: Memo, store: TimelineStore)? {
        if let timeline, let memo = memo(uid, in: timeline) { return (memo, timeline) }
        if let results = searchPresentation.search?.results, let memo = memo(uid, in: results) {
            return (memo, results)
        }
        if let timeline, let jumped, jumped.uid == uid { return (jumped, timeline) }
        return nil
    }

    /// Raises the sheet on a search that has never been used before.
    ///
    /// The client and the base URL are read here rather than inside the sheet because a search
    /// without a session is not a search: signed out there is no timeline either, and a loupe that
    /// opened an empty sheet would be the only control on the screen that pretended to work.
    private func openSearch() {
        guard let handle = session.activeHandle, let baseURL = session.serverBaseURL else { return }
        let search = MemoSearch(
            handle: handle,
            baseURL: baseURL,
            onUnauthorized: { [session] in await session.handle(.unauthorized) }
        )
        // The second `TimelineStore` in the app, and its failures are as much the session's as the
        // first one's (`SessionReporting`).
        search.reports(to: session)
        searchPresentation.open(search)
    }

    /// Every way the sheet closes funnels through here.
    ///
    /// A hand-off to the results screen is the one close that is not an abandonment: the results
    /// screen has just adopted this search's store — rows, cursor, AND any answer still on its
    /// way. Cancelling that answer here left the reader on a spinner over nothing whenever the
    /// network was slower than the dismissal animation (MEMNG-177, review round), so a hand-off
    /// touches nothing; the sheet's own section loads end with their `.task`s on teardown. Every
    /// other close (Done, an interactive swipe) abandons the search and resets it. The decision
    /// itself is `SearchPresentation.closeAction`, where it is asserted.
    private func dismissSearch() {
        switch SearchPresentation.closeAction(handingOff: handingOff) {
        case .adopt:
            handingOff = false
        case .abandon:
            searchPresentation.search?.stop()
        }
    }

    /// A tapped tile opens that attachment full screen, on the page it was tapped at — a video
    /// included, and a video arrives playing (`MediaViewerPlayback`). An attachment the viewer
    /// cannot show — an upload that is neither picture nor video — falls back to the memo,
    /// because a tap that does nothing at all reads as a broken card.
    private func open(_ attachment: MemoAttachment, of memo: Memo) {
        if let selection = MediaViewerPresentation.viewer(for: memo, startingAt: attachment.uid) {
            viewing = selection
        } else {
            path.append(MemoRoute(uid: memo.uid))
        }
    }

    /// Whether the live media channel belongs open right now. The rule itself is
    /// `MediaChannel.shouldRun`, where it can be asserted for every phase rather than observed on
    /// a device.
    private var mediaChannelRuns: Bool {
        MediaChannel.shouldRun(
            phase: MediaChannelPhase(scenePhase),
            signedIn: session.state.user != nil,
            hasTimeline: timeline != nil
        )
    }

    /// Ends the WAITING treatment without anybody pulling the timeline down: the server pushes an
    /// event as each attachment is derived, and the tile it belongs to flips where it sits.
    ///
    /// The reconciling read belongs to the CONNECTION, not to this call, so `consume` owns it and
    /// runs it at every open — see `MediaChannel.uidsToReconcile` for what a per-channel pass
    /// would miss. Everything this function does is hand over what a connection needs.
    ///
    /// The search's list is handed over as a CLOSURE, not as a second store, and deliberately not
    /// as part of the task's key: a search is opened and left far more often than the app is put
    /// away, and keying on it would close and reopen the connection every time. Read at each event
    /// instead, so the results screen is patched from the moment it exists and the connection
    /// never notices.
    ///
    /// WHICH lists those are is `SearchPresentation.liveResults`, and the answer is empty unless
    /// its screen is on the stack: the store is kept after the reader walks back — emptying it
    /// would cost them the rows and the cursor they walk into next time — so a channel that
    /// followed the store rather than the screen would go on scanning a list nobody can see for
    /// the rest of the session.
    private func runMediaChannel() async {
        guard mediaChannelRuns,
            let timeline,
            let handle = session.activeHandle,
            let baseURL = session.serverBaseURL
        else { return }
        // The channel reconnects for as long as this screen is up, so what it presents has to
        // keep proving it belongs to a session this device holds — asked by the transport, at
        // each connect. The session's OWN authority, not one assembled here: it carries the
        // credential and its epoch as well as the verdict, which is what lets the transport
        // present the token the device is holding NOW and the client tell a refusal of that from a
        // refusal of one it has already replaced (`SendAuthority`).
        await MediaChannel.consume(
            MediaEventClient.device(
                grant: { [session] in session.credentialGrant() },
                authority: session.sendAuthority()
            ).stream(),
            into: timeline,
            alongside: { [searchPresentation] in searchPresentation.liveResults },
            using: handle,
            baseURL: baseURL
        )
    }

    private func delete(_ memo: Memo, in timeline: TimelineStore) async {
        guard let handle = session.activeHandle else { return }
        if await timeline.delete(uid: memo.uid, using: handle) {
            feedback.fire(.deleted)
        }
    }

    private func setPinned(_ pinned: Bool, on memo: Memo, in timeline: TimelineStore) async {
        guard let handle = session.activeHandle, let baseURL = session.serverBaseURL else { return }
        guard await timeline.setPinned(pinned, uid: memo.uid, using: handle, baseURL: baseURL)
        else { return }
        feedback.fire(pinned ? .pinned : .unpinned)
    }

    /// A new memo is written to the OUTBOX, never straight to the network: the screen closes as
    /// soon as the capture is on disk, and the upload happens when the phone is somewhere it can.
    /// An edit still goes to the server directly — editing needs the memo to exist.
    private func submit(
        _ mode: ComposeView.Mode,
        submission: ComposeSubmission,
        to timeline: TimelineStore
    ) async -> ComposeOutcome {
        let outcome: ComposeOutcome
        switch mode {
        case .create:
            guard let outbox else { return .failed(.authorization) }
            let saved = await outbox.enqueue(
                content: submission.content,
                visibility: submission.visibility?.rawValue,
                // A backdated capture keeps the date it was given all the way through the queue:
                // the job's capture stamp IS what the create call sends as `created_at`. On Auto
                // that date is the earliest instant the attached files carried, resolved before
                // the sheet would let this be tapped.
                capturedAt: submission.capturedAt(),
                sources: submission.attachments.map(\.stagedSource)
            )
            outcome =
                saved
                ? .saved
                : .failed(
                    outbox.lastEnqueueFailure == .notSignedIn ? .authorization : .storage)
        case .edit(let uid, _, let createdAt):
            guard let handle = session.activeHandle, let baseURL = session.serverBaseURL else {
                return .failed(.authorization)
            }
            outcome = await timeline.edit(
                uid: uid,
                content: submission.content,
                createdAt: MemoDetailPresentation.editedDate(
                    chosen: submission.createdAt, original: createdAt
                ),
                // Files added to an EXISTING memo go up in the FOREGROUND: the outbox above owns
                // new captures, and an edit that failed is answered honestly on the sheet that is
                // still open rather than queued (outbox-backed edits are MEMNG-124's line).
                attaching: submission.attachments.map(\.stagedSource),
                using: handle,
                baseURL: baseURL
            )
        }
        feedback.fire(outcome.isSaved ? .posted : .postFailed)
        return outcome
    }

    /// Whose timeline this screen is showing — the pair a snapshot on disk is filed under.
    ///
    /// Nil until there is both a server and a user, which is also the only state in which nothing
    /// should be read off the disk: a snapshot with no signed-in identity to match against is
    /// somebody's memos and no way to tell whose.
    private var snapshotIdentity: TimelineSnapshotIdentity? {
        guard let server = session.serverBaseURL, let subject = session.state.user?.subject else {
            return nil
        }
        return TimelineSnapshotIdentity(server: server, subject: subject)
    }

    /// Everything this screen reads from the server, on the one signal that already means "read
    /// it again": the screen appearing, a pull, and a queued capture becoming a memo.
    ///
    /// One read, and it is the memos. The activity heatmap used to ride this signal too, which
    /// put a second request in front of every pull of a list nobody had asked a heatmap question
    /// of (MEMNG-166); it belongs to the search sheet now and is read when that opens
    /// (MEMNG-126).
    private func load() async {
        guard let handle = session.activeHandle, let baseURL = session.serverBaseURL else { return }
        await timeline?.refresh(using: handle, baseURL: baseURL)
    }

    /// A day chosen on the sheet: the list comes back anchored at that day.
    ///
    /// Whether the sheet stays up over it is the CHOICE's to say, not this function's. A scrub
    /// release or a picked date leaves it up (MEMNG-178): a scrubber that dismissed itself the
    /// moment a finger came off would be usable exactly once per opening, and an accidental lift
    /// mid-drag would be a jump nobody asked for with no way back but reopening the sheet. The
    /// commit row settles the day and takes the sheet with it (MEMNG-187), which is what puts the
    /// landing this produces in front of the reader.
    ///
    /// Anchored, not scrolled. The memo written on 4 June is a hundred cursor pages down a list
    /// that is still being paged, so scrolling to it would mean fetching everything in between;
    /// the server already takes `created_before` (`MemoQuery.anchor`), so the list is simply asked
    /// for from that day backwards and the reader arrives at the top of it.
    private func jump(to anchor: MemoQueryAnchor) {
        guard let timeline else { return }
        timeline.setQuery(MemoQuery(anchor: anchor))
        topWatch.settled()
        restoreTop = nil
        Task {
            await load()
            jumps += 1
        }
    }

    /// Back to now — the same list this screen opens with.
    private func clearAnchor() {
        guard let timeline else { return }
        timeline.setQuery(.empty)
        topWatch.settled()
        restoreTop = nil
        Task { await load() }
    }

    /// The page ABOVE an anchored list, and the reader put back where they were reading.
    ///
    /// The store decides whether there is anything above and refuses a second read while one is
    /// out, so arriving at the top repeatedly costs one request, not one per frame.
    private func loadNewer(in timeline: TimelineStore) async {
        guard timeline.shouldLoadNewer(before: 0) else { return }
        guard let handle = session.activeHandle, let baseURL = session.serverBaseURL else { return }
        guard let top = await timeline.loadNewer(using: handle, baseURL: baseURL) else { return }
        restoreTop = top
        restores += 1
    }

}

/// A section's heading — a day, "Pending", or a group of settings. Headline weight, because it is
/// a heading; the list it sits over had none at all before.
struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.vertical, DesignTokens.Space.tight)
    }
}

/// What the timeline says about itself while it is anchored at a day, and the way back to now.
///
/// Without it a jump is a one-way door: every refresh this screen has keeps the query it was
/// given, pulls included, so a list taken to a day in June stays there with nothing on screen to
/// say why it looks like that or how to leave.
struct TimelineAnchorNotice: View {
    let title: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.snug) {
            Label {
                Text(title).font(.subheadline)
            } icon: {
                Image(systemName: "calendar")
            }
            // Wrapping rather than truncating: at the accessibility sizes the sentence is longer
            // than the card, and a date cut in half is the one part of this row that has to be
            // readable.
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DesignTokens.Space.snug)
            TimelineAnchorClearButton(clear: clear)
        }
        .padding(DesignTokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
    }
}

/// The way back to now. Its own view because the row measures it: the notice puts a flexible gap
/// in front of it, and a flexible gap reports whatever width it is offered.
struct TimelineAnchorClearButton: View {
    let clear: () -> Void

    var body: some View {
        Button("Today", action: clear)
            .font(.subheadline.weight(.semibold))
    }
}

/// Something the app has to say, in the card shape everything else on this screen uses.
struct NoticeCard: View {
    enum Tone {
        case warning
        case error
    }

    let text: String
    let tone: Tone

    var body: some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(tone == .warning ? Color.orange : Color.red)
        .padding(DesignTokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
    }
}

extension View {
    /// The row chrome every card on this screen shares: no separator, no list background of its
    /// own, and the card's own inset. Written once so a new card cannot forget a piece of it and
    /// reintroduce the separator lines this phase removed.
    func cardRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(
                EdgeInsets(
                    top: 0,
                    leading: DesignTokens.Space.roomy,
                    bottom: 0,
                    trailing: DesignTokens.Space.roomy
                )
            )
    }
}

extension ComposeView.Mode: Identifiable {
    public var id: String {
        switch self {
        case .create: "create"
        case .edit(let uid, _, _): "edit-\(uid)"
        }
    }
}
