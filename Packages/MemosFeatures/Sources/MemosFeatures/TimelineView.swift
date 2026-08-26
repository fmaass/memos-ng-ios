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
    @State private var timeline: TimelineStore?
    /// The activity heatmap behind the card at the top of the scroll. Built here rather than in
    /// the `.task` the timeline is: it needs nothing from the session to exist, and a card that
    /// waits for a store to be constructed flickers in on the first frame after launch.
    @State private var heatmap = HeatmapStore()
    /// Folded away or not. Deliberately not persisted: the card is the timeline's header, and a
    /// header that starts hidden is one nobody finds again.
    @State private var heatmapExpanded = true
    @State private var composing: ComposeView.Mode?
    /// One conversation for the whole screen, shared with the Settings screen pushed from it —
    /// two stages would be two machines and, between them, two revokes.
    @State private var signOut = SignOutConversation()
    /// The account's picture, decoded once here and handed to both the toolbar and Settings.
    @State private var avatar: Image?
    /// Type-erased because the stack now leads to two different places: a memo, and Settings.
    @State private var path = NavigationPath()
    @State private var feedback = MemoFeedbackTrigger()
    /// The media a tile tap opened, full screen. A tapped video opens it too — on the video's
    /// own page, already playing — so the rest of the memo stays one swipe away.
    @State private var viewing: MediaViewerSelection?
    /// What the zoom transition matches the viewer to: the tile it grew out of.
    @Namespace private var mediaZoom
    /// The search the loupe raised, and the list it fills. Built fresh at every tap — a term left
    /// over from last time is a filter silently hiding memos, which is the worse failure (design
    /// note §5, Q4) — and kept here rather than inside the sheet because the results screen the
    /// sheet pushes outlives the sheet.
    @State private var search: MemoSearch?
    @State private var searching = false
    /// Set only for the one sheet close that is a hand-off to the results screen rather than
    /// an abandonment, so `dismissSearch` knows not to reset the store the results screen has
    /// just adopted.
    @State private var handingOff = false

    public init() {}

    public var body: some View {
        NavigationStack(path: $path) {
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
            .navigationDestination(for: SettingsRoute.self) { _ in
                SettingsView(signOut: signOut, avatar: avatar)
            }
            // The memo is looked for in BOTH lists. A card tapped on the search results is a
            // memo the home timeline has very often never loaded, and a destination that only
            // knew the timeline pushed an empty screen for exactly those memos. Whichever list
            // held it is also the list the detail screen edits, so an edit made from a result
            // lands where it was read.
            .navigationDestination(for: MemoRoute.self) { route in
                if let found = holder(of: route.uid) {
                    MemoDetailView(uid: route.uid, initial: found.memo, timeline: found.store)
                }
            }
            .navigationDestination(for: SearchResultsRoute.self) { _ in
                if let search {
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
                    avatar: avatar,
                    name: session.state.user?.name,
                    composed: feedback.count,
                    openSettings: { path.append(SettingsRoute()) },
                    signOut: { signOut.send(.menuTapped, to: session) },
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
            .sheet(isPresented: $searching, onDismiss: dismissSearch) {
                if let search {
                    SearchSheet(
                        search: search,
                        close: { searching = false },
                        showResults: {
                            handingOff = true
                            searching = false
                            path.append(SearchResultsRoute())
                        }
                    )
                }
            }
        }
        // On the navigation stack rather than further down the chain, so it is a different view
        // from the one presenting the compose sheet — two presentations on one view is how one of
        // them silently stops appearing.
        .fullScreenCover(item: $viewing) { selection in
            MediaViewerView(selection: selection)
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
        .task {
            if timeline == nil {
                timeline = TimelineStore(onUnauthorized: { [session] in
                    await session.handle(.unauthorized)
                })
            }
            await load()
            // What "Default" resolves to is the account's setting, not something the app can
            // guess. It is fetched here rather than during sign-in so a slow or missing
            // /api/settings can never hold up getting someone into the app.
            await session.loadSettings()
            // Adopt whatever the last run left in flight before anything new is scheduled.
            await outbox?.start()
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
        // A capture that leaves the queue has become a memo on the server; the list it belongs in
        // is reloaded so it does not appear to have vanished.
        .onChange(of: outbox?.lastCompletedAt) { _, _ in
            Task { await load() }
        }
    }

    @ViewBuilder
    private func content(_ timeline: TimelineStore) -> some View {
        // The flat position of each memo, so the prefetch trigger still knows how close to the
        // end of the LIST a row is once the list has been cut into days.
        let positions = Dictionary(
            uniqueKeysWithValues: timeline.memos.enumerated().map { ($1.uid, $0) }
        )
        List {
            // The scroll's header: what the household has been writing, above everything the
            // list itself is about.
            HeatmapCard(
                grid: HeatmapPresentation.grid(from: heatmap.counts),
                expanded: $heatmapExpanded
            )
            .cardRow()
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
                            guard let client = session.api, let baseURL = session.serverBaseURL
                            else { return }
                            await timeline.loadMore(using: client, baseURL: baseURL)
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
                        guard let client = session.api,
                            let baseURL = session.serverBaseURL
                        else { return }
                        await timeline.setVisibility(
                            option, uid: memo.uid, using: client, baseURL: baseURL
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
    private func holder(of uid: String) -> (memo: Memo, store: TimelineStore)? {
        if let timeline, let memo = memo(uid, in: timeline) { return (memo, timeline) }
        if let results = search?.results, let memo = memo(uid, in: results) {
            return (memo, results)
        }
        return nil
    }

    /// Raises the sheet on a search that has never been used before.
    ///
    /// The client and the base URL are read here rather than inside the sheet because a search
    /// without a session is not a search: signed out there is no timeline either, and a loupe that
    /// opened an empty sheet would be the only control on the screen that pretended to work.
    private func openSearch() {
        guard let client = session.api, let baseURL = session.serverBaseURL else { return }
        search = MemoSearch(
            client: client,
            baseURL: baseURL,
            onUnauthorized: { [session] in await session.handle(.unauthorized) }
        )
        searching = true
    }

    /// Every way the sheet closes funnels through here.
    ///
    /// A hand-off to the results screen is the one close that is not an abandonment — the
    /// results screen has just adopted this search's store — so it cancels any stray task but
    /// keeps the loaded rows and their cursor. Every other close (Done, an interactive swipe)
    /// abandons the search and resets it.
    private func dismissSearch() {
        if handingOff {
            handingOff = false
            search?.cancelInFlight()
        } else {
            search?.stop()
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
    private func runMediaChannel() async {
        guard mediaChannelRuns,
            let timeline,
            let client = session.api,
            let baseURL = session.serverBaseURL
        else { return }
        await MediaChannel.consume(
            MediaEventClient.device().stream(),
            into: timeline,
            using: client,
            baseURL: baseURL
        )
    }

    private func delete(_ memo: Memo, in timeline: TimelineStore) async {
        guard let client = session.api else { return }
        if await timeline.delete(uid: memo.uid, using: client) {
            feedback.fire(.deleted)
            // A day just lost a memo. The heatmap is a count, not a list, so nothing else on this
            // screen would have told it — and a square that stays dark until the next launch is
            // the app disagreeing with itself.
            await heatmap.load(using: client)
        }
    }

    private func setPinned(_ pinned: Bool, on memo: Memo, in timeline: TimelineStore) async {
        guard let client = session.api, let baseURL = session.serverBaseURL else { return }
        guard await timeline.setPinned(pinned, uid: memo.uid, using: client, baseURL: baseURL)
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
    ) async -> Bool {
        let posted: Bool
        switch mode {
        case .create:
            guard let outbox else { return false }
            posted = await outbox.enqueue(
                content: submission.content,
                visibility: submission.visibility?.rawValue,
                // A backdated capture keeps the date it was given all the way through the queue:
                // the job's capture stamp IS what the create call sends as `created_at`.
                capturedAt: submission.capturedAt(),
                sources: submission.attachments.map(\.stagedSource)
            )
        case .edit(let uid, _, let createdAt):
            guard let client = session.api, let baseURL = session.serverBaseURL else {
                return false
            }
            posted = await timeline.edit(
                uid: uid,
                content: submission.content,
                createdAt: MemoDetailPresentation.editedDate(
                    chosen: submission.createdAt, original: createdAt
                ),
                using: client,
                baseURL: baseURL
            )
        }
        feedback.fire(posted ? .posted : .postFailed)
        return posted
    }

    /// Everything this screen reads from the server, on the one signal that already means "read
    /// it again": the screen appearing, a pull, and a queued capture becoming a memo. The heatmap
    /// rides that signal rather than owning one of its own — a second refresh path is a second
    /// thing to forget when a third way of creating a memo arrives.
    private func load() async {
        guard let client = session.api, let baseURL = session.serverBaseURL else { return }
        await timeline?.refresh(using: client, baseURL: baseURL)
        await heatmap.load(using: client)
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
