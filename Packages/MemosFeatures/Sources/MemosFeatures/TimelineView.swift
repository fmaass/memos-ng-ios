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
    /// The session's trips and their members, moved to a new identity beside the timeline.
    @Environment(TripStore.self) private var trips: TripStore?
    @Environment(TripMemberStore.self) private var tripMembers: TripMemberStore?
    /// The tabs' dock, which the list's scrolls are told to; nil when hosted without the tabs.
    @Environment(AppDock.self) private var dock: AppDock?
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
    /// The delete conversation the edit sheet can start, and the one thing that decides what its
    /// answer may write. The SAME coordinator the memo's own screen uses — a second delete path
    /// would be a second set of rules about when a memo may be removed.
    @State private var memoDelete = MemoEditFlow()
    /// One conversation for the whole screen, handed to the account sheet opened from it — two
    /// stages would be two machines and, between them, two revokes.
    @State private var signOut = SignOutConversation()
    /// The account's picture, decoded once here and handed to the toolbar and the account sheet.
    @State private var avatar: Image?
    /// Whether the account sheet is up; the avatar top-left opens it (`accountSheet`).
    @State private var accountOpen = false
    /// Type-erased: the stack led to a memo and to Settings until the chrome trim (2026-10-10), and
    /// is left so rather than re-typed in a change that is about the toolbar.
    @State private var path = NavigationPath()
    @State private var feedback = MemoFeedbackTrigger()
    /// The media a tile tap opened, full screen. A tapped video opens it too — on the video's
    /// own page, already playing — so the rest of the memo stays one swipe away.
    @State private var viewing: MediaViewerSelection?
    /// The memo `viewing` was opened from. A memo's attachments do not name their memo
    /// (`MemoAttachment.memoUID` is the library's field), so it is kept beside the selection.
    @State private var viewingMemo: String?
    /// What the zoom transition matches the viewer to: the tile it grew out of.
    @Namespace private var mediaZoom

    public init() {}

    public var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let timeline {
                    content(timeline)
                        // A tile whose signature lapsed asks for its memo to be read again.
                        .environment(\.signedURLRefresher, refresher(for: timeline))
                } else {
                    ProgressView()
                }
            }
            .background(Color(.systemGroupedBackground))
            // The app's main bar's room, inside the stack (MEMNG-690).
            .leadingFootBar(on: .timeline)
            // No title (MEMNG-756): the main bar's selected item already names the tab, and a
            // large title spent a band of the screen saying it again. The toolbar keeps both its
            // controls exactly where they were.
            .modifier(TabRootChrome())
            // `stackDestination`, not `navigationDestination`: what the tab bar does under a
            // pushed screen is the route's to say (MEMNG-220).
            //
            // The memo is looked for in the timeline, and then as the one a Library jump read
            // for this push (`holder(of:)`); either way the detail screen edits through the
            // timeline store.
            .stackDestination(for: MemoRoute.self) { route in
                if let found = holder(of: route.uid) {
                    MemoDetailView(uid: route.uid, initial: found.memo, timeline: found.store)
                }
            }
            // Top-LEFT is the account's face, opening its sheet; top-RIGHT is New memo, alone since
            // the loupe went (MEMNG-513). Which is which is decided in `TimelineToolbar` rather
            // than here — a placement written inline in a screen that needs a live session to
            // construct is one no test can read back.
            //
            // This screen's job is only to say what the bar is showing and what its controls do.
            .toolbar {
                TimelineToolbar(
                    composed: feedback.count,
                    avatar: avatar,
                    name: session.state.user?.name ?? "",
                    openAccount: { accountOpen = true },
                    newMemo: { composing = .create(restoring: nil) }
                )
            }
        }
        // On the navigation stack rather than further down the chain, so it is a different view
        // from the one presenting the compose sheet — two presentations on one view is how one of
        // them silently stops appearing.
        .fullScreenCover(item: $viewing) { selection in
            // A memo's media never grows, but its signatures lapse: the viewer reads the memo as
            // the timeline holds it, so a re-read with fresh URLs reaches a page already open.
            MediaViewerView(
                selection: selection,
                source: Self.viewerSource(for: selection, memo: viewingMemo, in: timeline)
            )
            .environment(\.signedURLRefresher, timeline.map(refresher(for:)))
            .mediaZoomTransition(sourceID: selection.id, in: mediaZoom)
        }
        .tint(DesignTokens.accent)
        // A press on the Timeline while it shows goes back to the list (MEMNG-781).
        .onTabReselected(.timeline) { path = NavigationPath() }
        .sensoryFeedback(trigger: feedback) { _, latest in latest.act?.feedback }
        .sheet(item: $composing, onDismiss: { memoDelete.dismiss() }) { mode in
            if let timeline {
                Self.editSheet(
                    mode: mode,
                    isAsking: memoDelete.deleteStage == .asking,
                    failure: memoDelete.lastError,
                    // Read from the store as the sheet opens; the sheet keeps the first answer.
                    pinnedTrip: ComposePinnedTrip.offered(from: trips, now: Date()),
                    send: { event in
                        memoDelete.sendDelete(event) { uid in
                            await delete(uid: uid, in: timeline)
                        }
                    }
                ) { submission in
                    await submit(mode, submission: submission, to: timeline)
                }
            }
        }
        // The coordinator opens and closes WITH the sheet. The timeline keeps its own state for
        // the save it already does; what the delete needs from here is which memo is being edited
        // and which opening of the sheet is the current one.
        .onChange(of: composing) { _, mode in memoDelete.begin(mode) }
        .onChange(of: memoDelete.memoDeleted) { _, gone in
            // A memo that is gone has no sheet to be edited in. The memo's own screen leaves
            // instead; here there is nothing to leave, so the sheet is what goes.
            if gone { composing = nil }
        }
        // The sheet and the sign-out alerts together: while the sheet is up its own stack asks and
        // this one is muted, and once it is down this one asks again — so a revoke the sheet's
        // dismissal outlived is still explained here.
        .accountSheet(isPresented: $accountOpen, signOut: signOut, avatar: avatar)
        // Decoded once, here, because the toolbar shows it on every frame of the timeline and the
        // account sheet shows it again — one decode, handed to both.
        .task(id: session.avatar) { avatar = await AccountAvatar.image(from: session.avatar) }
        // The foreground trigger, and one of only two the re-validation has. `initial: true`
        // because a timeline created while the app is ALREADY active never sees a change — which
        // is every launch — and the session's single-flight absorbs the overlap with the launch
        // check this joins.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                // A phone put away on a train and taken out at home comes back to whatever its
                // pictures ended as. Nothing about a tile changes when the app is reopened, so
                // this is the only moment that can tell one it is worth asking again.
                MediaRetrySignal.shared.publish()
                Task { await session.enteredForeground() }
            case .background, .inactive: session.enteredBackground()
            @unknown default: break
            }
        }
        .task {
            if timeline == nil {
                let store = TimelineStore(
                    // The days this screen is anchored at are the server's UTC ones — see
                    // `HeatmapDateJump.anchorCalendar` for what reading them in the device's zone
                    // would hide.
                    calendar: HeatmapDateJump.anchorCalendar,
                    snapshots: session.snapshots,
                    snapshotIdentity: snapshotIdentity,
                    // The one list in the app that is worth opening on tomorrow.
                    persists: true,
                    onUnauthorized: { [session] refusal in
                        await session.handle(refusal)
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
        // sent is left alone. The identity is the whole pair: the same subject on another server
        // is another account, and its collections are filed apart.
        .onSessionIdentityChange(snapshotIdentity) { identity in
            timeline?.sessionIdentityChanged(to: identity)
            CollectionsSession.identityChanged(
                to: identity, trips: trips, members: tripMembers)
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
        // The server is answering again, and this list was read while it was not.
        .reloadsOnRecovery(session.reachabilityRecoveries) { await load() }
        // A memo asked for from the Library. Keyed on the request rather than run from an
        // `onChange`, because satisfying it can mean reading the memo from the server first and
        // that read must be cancellable with the screen.
        .task(id: jump?.pending) { await consumeJump() }
    }

    /// The viewer over a memo's media, reading the memo through the timeline when it can name it.
    static func viewerSource(
        for selection: MediaViewerSelection,
        memo memoUID: String?,
        in timeline: TimelineStore?
    ) -> MediaViewerSource {
        guard let memoUID else { return .fixed(selection.pages) }
        return .memo(uid: memoUID, in: timeline, fallback: selection.pages)
    }

    private func refresher(for timeline: TimelineStore) -> MemoURLRefresher {
        MemoURLRefresher(timeline: timeline, session: IssuingSession(session))
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
                // the one that was on screen.
                topWatch.settled()
                restoreTop = nil
                jumps += 1
                path.append(MemoRoute(uid: uid))
            case .unavailable:
                // Switching tabs and then doing nothing reads as the app losing the tap. Say what
                // happened instead: the memo is gone, or it is not in the list this screen shows.
                jumpNotice = "That memo is no longer here."
            case .unreadable:
                // The read failed — dropped on the way, or refused by the server with an error of
                // its own — so nothing here knows whether the memo is still there, and saying it
                // is gone would be a guess, and the wrong one. When it was the server that could
                // not be reached, the banner above this says so, once.
                jumpNotice = "That memo couldn't be opened just now."
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
                // The reader's scrolls fold and unfold the leading bar (MEMNG-690).
                .feedsDock(dock, on: .timeline)
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
                PendingSection(
                    jobs: outbox.jobs,
                    lastProgressAt: outbox.lastProgressAt,
                    verdict: outbox.uploadVerdict,
                    retry: { id in Task { await outbox.retry(id) } },
                    remove: { id in Task { await outbox.discard(id) } },
                    restore: { id in
                        Task {
                            // The queue hands the draft back or it does not; a change the server
                            // has not answered yet is refused, and a restore that found nothing to
                            // stop opens no sheet.
                            if let draft = await outbox.cancel(id) {
                                composing = .create(restoring: ComposeRestore(draft))
                            }
                        }
                    }
                )
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
                                    composing = Self.editMode(for: memo)
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

    /// What the long-press Edit opens on: the memo as it stands, its pictures included.
    ///
    /// Named rather than written inside the menu because a context menu never opens under a test,
    /// and what this carries — the memo's own attachments, not an empty list — is the whole of
    /// what the sheet has to show.
    static func editMode(for memo: Memo) -> ComposeView.Mode {
        .edit(
            uid: memo.uid,
            content: memo.content,
            createdAt: memo.createdAt,
            attachments: memo.attachments
        )
    }

    /// What the long press opens: the compose screen a new capture uses, with the destructive row
    /// on an EDIT and nothing on a new memo, which has nothing to delete.
    ///
    /// Named rather than written inside `.sheet` for the reason `editMode(for:)` is: a sheet never
    /// presents under a test, so the only honest way to hold "the sheet this screen opens really
    /// offers Delete" is to build its content the way this screen builds it and put THAT up.
    ///
    /// The sentence the sheet carries is shown HERE rather than around the call that presents it,
    /// and for the same reason this factory exists at all: the screen's own notices are rows of its
    /// list, and the sheet is drawn over the list — so a delete the server refused was answered
    /// where nobody with the sheet open could see it. Nothing comes back through `ComposeDelete`
    /// for the sheet to say for itself.
    ///
    /// `pinnedTrip` reaches a NEW memo only: the pin is for captures, and an edit is never
    /// offered it.
    static func editSheet(
        mode: ComposeView.Mode,
        isAsking: Bool,
        failure: String?,
        pinnedTrip: ComposePinnedTrip? = nil,
        send: @escaping @MainActor (MemoEditFlow.DeleteEvent) -> Void,
        submit: @escaping (ComposeSubmission) async -> ComposeOutcome
    ) -> some View {
        VStack(spacing: 0) {
            if let failure {
                // Padded rather than given `cardRow()`: that is list-row chrome, and this is not
                // a list.
                NoticeCard(text: failure, tone: .error)
                    .padding(.horizontal, DesignTokens.Space.roomy)
                    .padding(.top, DesignTokens.Space.regular)
            }
            if case .edit = mode {
                ComposeView(
                    mode: mode,
                    delete: ComposeDelete(isAsking: isAsking, send: send),
                    submit: submit
                )
            } else {
                ComposeView(mode: mode, pinnedTrip: pinnedTrip, submit: submit)
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

    /// The list a memo was read from, and the memo. The timeline first: it is the canonical list.
    ///
    /// The second case is a memo NOT in it: one reached by a jump from the Library, read from the
    /// server for exactly this push. It is last because it is the only copy that is not part of a
    /// list anything else is reading — the detail screen still edits through the timeline store,
    /// and this value only stands in until that store has one of its own.
    private func holder(of uid: String) -> (memo: Memo, store: TimelineStore)? {
        if let timeline, let memo = memo(uid, in: timeline) { return (memo, timeline) }
        if let timeline, let jumped, jumped.uid == uid { return (jumped, timeline) }
        return nil
    }

    /// A tapped tile opens that attachment full screen, on the page it was tapped at — a video
    /// included, and a video arrives playing (`MediaViewerPlayback`). An attachment the viewer
    /// cannot show — an upload that is neither picture nor video — falls back to the memo,
    /// because a tap that does nothing at all reads as a broken card.
    private func open(_ attachment: MemoAttachment, of memo: Memo) {
        if let selection = MediaViewerPresentation.viewer(for: memo, startingAt: attachment.uid) {
            viewingMemo = memo.uid
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

    /// The request the edit sheet's Delete sends. WHEN it runs — once, for the memo whose sheet
    /// confirmed it, and only after a question was answered — is `MemoEditFlow`'s decision, and
    /// the store is what makes two of them one request on the wire.
    private func delete(uid: String, in timeline: TimelineStore) async -> Bool {
        guard let handle = session.activeHandle else { return false }
        let deleted = await timeline.delete(uid: uid, using: handle)
        feedback.fire(deleted ? .deleted : .postFailed)
        return deleted
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
        case .create(let restored):
            guard let outbox else { return .failed(.authorization) }
            // Read together, in one synchronous step: the default is only true of the account it
            // was read under, and that account travels with it to the enqueue.
            let composed = session.snapshotIdentity.map {
                ComposedAccountDefault(
                    visibility: session.defaultVisibility,
                    account: AccountBinding(serverBaseURL: $0.server, ownerSubject: $0.subject))
            }
            switch await Self.post(
                submission,
                restoring: restored,
                accountDefault: composed,
                resubmit: { await outbox.resubmit($0, draft: $1) },
                enqueue: { await Self.enqueue($0, into: outbox, accountDefault: $1) }
            ) {
            case .saved:
                outcome = .saved
            case .refused(let failure):
                outcome = .failed(failure)
            case .enqueueFailed:
                outcome = .failed(
                    outbox.lastEnqueueFailure == .notSignedIn ? .authorization : .storage)
            }
        case .edit(let uid, _, let createdAt, _):
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
                listing: submission.pictures,
                using: handle,
                baseURL: baseURL
            )
        }
        feedback.fire(outcome.isSaved ? .posted : .postFailed)
        return outcome
    }

    /// What Post did, for the one caller that turns it into a sheet answer. A Bool could only
    /// say "no": the three ways out differ in what the sheet must do next.
    enum PostOutcome: Equatable {
        case saved
        case enqueueFailed
        case refused(ComposeFailure)
    }

    /// What Post does with a create, decided once. A capture the editor was HANDED goes back to
    /// the job it came out of: same manifest, same key, so a create that already committed
    /// resolves to its own memo. A job that vanished under the open editor has nothing left to go
    /// back to, and the words and files on this screen are not thrown away for it — they become a
    /// new capture.
    ///
    /// "Default" on the picker is a word, not a value a memo can carry. It resolves HERE to the
    /// account's own choice WHEN that choice is known; when it is not, Post refuses and says so for
    /// a capture that carries a visibility of its own, because sending nothing would hand the queue
    /// its own fallback — that visibility, exactly the one the person just stopped choosing. A
    /// capture restored with none opened on Default, so no choice was stopped and none is sent.
    @MainActor
    static func post(
        _ submission: ComposeSubmission,
        restoring restored: ComposeRestore?,
        accountDefault composed: ComposedAccountDefault? = nil,
        resubmit: (UUID, RestoredDraft) async -> ResubmitOutcome,
        enqueue: (ComposeSubmission, ComposedAccountDefault?) async -> Bool
    ) async -> PostOutcome {
        guard let restored else {
            return await enqueue(submission, composed) ? .saved : .enqueueFailed
        }
        let accountDefault = composed?.visibility
        // "Default" with no account default known is a word this app cannot turn into a value.
        // Sending nothing would hand the queue its own fallback — the visibility the job already
        // has, which is the one the person just stopped choosing — so Post refuses. A capture
        // restored with none opened on Default: nothing was stopped, so nil goes.
        if submission.visibility == nil, accountDefault == nil, restored.visibility != nil {
            return .refused(.defaultVisibilityUnknown)
        }
        let visibility = (submission.visibility ?? accountDefault)?.rawValue
        let draft = RestoredDraft(submission, jobID: restored.jobID, visibility: visibility)
        switch await resubmit(restored.jobID, draft) {
        case .accepted: return .saved
        // Only a job that is GONE becomes a second capture. A refusal is not that: the capture
        // may already have committed a memo, and a fresh key would be a second one.
        case .vanished: return await enqueue(submission, composed) ? .saved : .enqueueFailed
        case .refused(let reason): return .refused(.captureUnchanged(reason))
        }
    }

    /// A new capture is stamped with the visibility it was composed under. "Default" resolves to
    /// the account's choice as it stands NOW, because sending nothing would let the server apply
    /// whatever the default is when the queue drains — hours later, after the person may have
    /// changed it (MEMNG-776). With no account default known yet, nil still goes: that is a
    /// capture staged before the account had an answer, and refusing it would lose the capture.
    /// The account the default was read under goes along, and the outbox refuses the capture if
    /// another account is the one it would be bound to.
    @MainActor
    static func enqueue(
        _ submission: ComposeSubmission,
        into outbox: Outbox,
        accountDefault composed: ComposedAccountDefault?
    ) async -> Bool {
        await outbox.enqueue(
            content: submission.content,
            visibility: (submission.visibility ?? composed?.visibility)?.rawValue,
            // A backdated capture keeps the date it was given all the way through the queue: the
            // job's capture stamp IS what the create call sends as `created_at`. On Auto that date
            // is the earliest instant the attached files carried, resolved before the sheet would
            // let this be tapped.
            capturedAt: submission.capturedAt(),
            sources: submission.attachments.map(\.stagedSource),
            composedUnder: composed?.account
        )
    }

    /// Whose timeline this screen is showing — the pair a snapshot on disk is filed under.
    ///
    /// Nil until there is both a server and a user, which is also the only state in which nothing
    /// should be read off the disk: a snapshot with no signed-in identity to match against is
    /// somebody's memos and no way to tell whose.
    private var snapshotIdentity: TimelineSnapshotIdentity? { session.snapshotIdentity }

    /// Everything this screen reads from the server, on the one signal that already means "read
    /// it again": the screen appearing, a pull, and a queued capture becoming a memo.
    ///
    /// One read, and it is the memos. The activity heatmap used to ride this signal too, which
    /// put a second request in front of every pull of a list nobody had asked a heatmap question
    /// of (MEMNG-166); it moved to the search sheet (MEMNG-126) and went with it (MEMNG-513).
    private func load() async {
        guard let handle = session.activeHandle, let baseURL = session.serverBaseURL else { return }
        await timeline?.refresh(using: handle, baseURL: baseURL)
        // The list has been read again, so the links on it are as fresh as the server will make
        // them — and a tile still owed its picture has a reason to ask once more. The URLs alone
        // cannot say so: the server buckets a signed link's expiry, so a read a minute later
        // commonly hands back the identical URL and no tile sees anything change.
        MediaRetrySignal.shared.publish()
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
        case .edit(let uid, _, _, _): "edit-\(uid)"
        }
    }
}

/// The account's default visibility as Post read it, and the account it was read under. One
/// value, because the default is an account-scoped read: judged against any other account it is
/// somebody else's answer.
struct ComposedAccountDefault: Sendable {
    /// Nil while the account has not said yet.
    var visibility: MemoVisibility?
    var account: AccountBinding
}

extension SessionStore {
    /// Whose data this session reads — the pair a timeline snapshot and the trips' pins file are
    /// filed under. Nil until there is both a server and a user.
    var snapshotIdentity: TimelineSnapshotIdentity? {
        guard let server = serverBaseURL, let subject = state.user?.subject else { return nil }
        return TimelineSnapshotIdentity(server: server, subject: subject)
    }
}
