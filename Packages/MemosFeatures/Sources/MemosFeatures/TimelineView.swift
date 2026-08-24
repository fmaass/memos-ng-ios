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
    @State private var timeline: TimelineStore?
    @State private var composing: ComposeView.Mode?
    @State private var signOutStage = SignOutFlow.Stage.idle
    @State private var path: [MemoRoute] = []
    @State private var feedback = MemoFeedbackTrigger()
    /// The picture a tile tap opened, full screen.
    @State private var viewing: MediaViewerSelection?
    /// The video a tile tap started. A tapped video plays; it does not open a page showing a
    /// still of itself with a play button on it.
    @State private var playing: VideoPlayback?
    /// What the zoom transition matches the viewer to: the tile it grew out of.
    @Namespace private var mediaZoom

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
            .navigationDestination(for: MemoRoute.self) { route in
                if let timeline, let memo = memo(route.uid, in: timeline) {
                    MemoDetailView(uid: route.uid, initial: memo, timeline: timeline)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        composing = .create
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .symbolEffect(.bounce, value: feedback.count)
                    }
                    .accessibilityLabel("New memo")
                }
                ToolbarItem(placement: .topBarLeading) {
                    // Signing out is a rare, deliberate act on a personal device — it lives
                    // behind the overflow, not beside the compose button someone taps daily.
                    //
                    // The heading is not decoration. A menu opens with its first ROW under the
                    // anchor that opened it, and when that row was the destructive one a second
                    // tap on the ellipsis revoked a live credential. The heading takes that
                    // position, and the tap itself only ever asks (see SignOutFlow).
                    Menu {
                        Section(SignOutFlow.accountHeading(name: session.state.user?.name)) {
                            Button(role: .destructive) {
                                advanceSignOut(.menuTapped)
                            } label: {
                                Label(
                                    "Sign out",
                                    systemImage: "rectangle.portrait.and.arrow.right"
                                )
                            }
                            // The destructive role reddens the WORDS; the glyph beside them is
                            // drawn in the inherited tint, which is the app's green — so the one
                            // row that should read as dangerous had a friendly icon on it.
                            .tint(.red)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
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
        // Attached here rather than beside the viewer's cover above: two presentations on ONE view
        // is how one of them silently stops appearing.
        .fullScreenCover(item: $playing) { playback in
            VideoPlayerView(playback: playback)
        }
        // The question the menu tap asks. It is not drawn under the anchor, so no repeat of the
        // tap that opened the menu can land on it.
        //
        // An ALERT rather than a confirmation dialog: the dialog rendered as a glass card that
        // dimmed nothing, left the timeline legible underneath, and — the part that matters —
        // put its Cancel button neither on screen nor in the accessibility tree, so the only
        // visible answer to "Sign out?" was "Sign out". An alert dims, shows both answers, and
        // hands both to VoiceOver.
        .alert(
            "Sign out?",
            isPresented: .init(
                get: { signOutStage == .asking },
                set: { if !$0 { advanceSignOut(.cancelled) } }
            )
        ) {
            Button("Sign out", role: .destructive) { advanceSignOut(.confirmed) }
            Button("Cancel", role: .cancel) { advanceSignOut(.cancelled) }
        } message: {
            Text("This device's access is revoked. Anything still queued stays on the phone.")
        }
        .alert(
            "Could not sign out",
            isPresented: .init(
                get: { signOutExplanation != nil },
                set: { if !$0 { advanceSignOut(.cancelled) } }
            ),
            presenting: signOutExplanation
        ) { decision in
            Button("Try again") { advanceSignOut(.confirmed) }
            Button(decision.discardTitle, role: .destructive) {
                Task {
                    await session.signOutWithoutRevoking()
                    signOutStage = .idle
                }
            }
            Button("Cancel", role: .cancel) { advanceSignOut(.cancelled) }
        } message: { decision in
            Text(decision.message)
        }
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
            if let outbox, !outbox.jobs.isEmpty {
                Section {
                    ForEach(PendingMemoPresentation.rows(for: outbox.jobs)) { row in
                        PendingCard(row: row) {
                            Task { await outbox.retry(row.id) }
                        }
                        .cardRow()
                    }
                } header: {
                    DayHeader(title: "Pending")
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
                            openAttachment: { open($0, of: memo) },
                            openPlayback: { play($0) }
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
                        // Ends the WAITING treatment without anybody pulling the timeline down.
                        // Keyed on whether this memo is still waiting, so the loop is started when
                        // it becomes true and torn down when it stops being true — and cancelled
                        // by SwiftUI when the row itself goes away.
                        .task(id: memo.isAwaitingTiers) {
                            guard memo.isAwaitingTiers else { return }
                            await pollTiers(memo.uid, in: timeline)
                        }
                    }
                } header: {
                    DayHeader(title: TimelineGrouping.title(for: section.day))
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

    /// A tapped tile opens that picture full screen, on the page it was tapped at. An attachment
    /// the viewer cannot show — an upload that is neither picture nor video — falls back to the
    /// memo, because a tap that does nothing at all reads as a broken card.
    private func open(_ attachment: MemoAttachment, of memo: Memo) {
        if let selection = MediaViewerPresentation.viewer(for: memo, startingAt: attachment.uid) {
            viewing = selection
        } else {
            path.append(MemoRoute(uid: memo.uid))
        }
    }

    /// A tapped video plays, immediately. The viewer's poster page for it is what a SWIPE reaches
    /// — a direct tap on a video is unambiguous, and it means play it.
    ///
    /// A video with no streamable rendition never routes here (`MemoCardTap.plays`), so there is
    /// nothing to fall back to.
    private func play(_ attachment: MemoAttachment) {
        guard let url = MemoPresentation.playbackURL(for: attachment) else { return }
        playing = VideoPlayback(url: url)
    }

    /// Re-reads a memo whose attachments the server has not finished deriving, on a capped
    /// backoff, until it has.
    ///
    /// SEAM (phase 5c): this is the INTERIM. `GET /api/events` (SSE) already pushes media-ready
    /// events to the web app; when this client subscribes to that stream, this call and
    /// `TierReadinessPoll` behind it go, and `TimelineStore.refreshMemo` becomes the handler for
    /// one event.
    private func pollTiers(_ uid: String, in timeline: TimelineStore) async {
        guard let client = session.api, let baseURL = session.serverBaseURL else { return }
        await TierReadinessPoll.run(uid: uid, in: timeline, using: client, baseURL: baseURL)
    }

    private func delete(_ memo: Memo, in timeline: TimelineStore) async {
        guard let client = session.api else { return }
        if await timeline.delete(uid: memo.uid, using: client) {
            feedback.fire(.deleted)
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

    private var signOutExplanation: SignOutFlow.Decision? {
        guard case .explaining(let decision) = signOutStage else { return nil }
        return decision
    }

    /// The single place a sign-out can start. The revoke is fired on the TRANSITION into
    /// `revoking`, never on an event, so no repeat of any tap can send a second one.
    private func advanceSignOut(_ event: SignOutFlow.Event) {
        let previous = signOutStage
        signOutStage = SignOutFlow.next(previous, on: event)
        guard SignOutFlow.revokes(signOutStage), !SignOutFlow.revokes(previous) else { return }
        Task {
            let outcome = await session.signOut()
            advanceSignOut(.revokeReturned(outcome))
        }
    }

    private func load() async {
        guard let client = session.api, let baseURL = session.serverBaseURL else { return }
        await timeline?.refresh(using: client, baseURL: baseURL)
    }

}

/// A day, or "Pending". Headline weight, because it is a heading — the old list had none at all.
struct DayHeader: View {
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
