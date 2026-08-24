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
    @State private var signOutDecision: SignOutFlow.Decision?
    @State private var path: [MemoRoute] = []
    @State private var feedback = MemoFeedbackTrigger()

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
            .navigationTitle("Memos")
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
                    Menu {
                        Button(role: .destructive) {
                            Task { await signOut() }
                        } label: {
                            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
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
        .alert(
            "Could not sign out",
            isPresented: .init(
                get: { signOutDecision != nil },
                set: { if !$0 { signOutDecision = nil } }
            ),
            presenting: signOutDecision
        ) { decision in
            Button("Try again") { Task { await signOut() } }
            Button(decision.discardTitle, role: .destructive) {
                session.signOutWithoutRevoking()
            }
            Button("Cancel", role: .cancel) {}
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
            ForEach(TimelineGrouping.sections(for: timeline.memos)) { section in
                Section {
                    ForEach(section.memos) { memo in
                        Button {
                            path.append(MemoRoute(uid: memo.uid))
                        } label: {
                            MemoCard(memo: memo)
                        }
                        .buttonStyle(.plain)
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
                                    composing = .edit(uid: memo.uid, content: memo.content)
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
                sources: submission.attachments.map(\.stagedSource)
            )
        case .edit(let uid, _):
            guard let client = session.api, let baseURL = session.serverBaseURL else {
                return false
            }
            posted = await timeline.edit(
                uid: uid, content: submission.content, using: client, baseURL: baseURL
            )
        }
        feedback.fire(posted ? .posted : .postFailed)
        return posted
    }

    private func signOut() async {
        signOutDecision = SignOutFlow.decision(for: await session.signOut())
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
        case .edit(let uid, _): "edit-\(uid)"
        }
    }
}
