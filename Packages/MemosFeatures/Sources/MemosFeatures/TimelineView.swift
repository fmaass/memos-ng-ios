import MemosCore
import SwiftUI

/// The timeline: one cursor-paginated page at a time, pull to refresh — and, since Phase 4,
/// the place memos are made and managed.
public struct TimelineView: View {
    @Environment(SessionStore.self) private var session
    @State private var timeline: TimelineStore?
    @State private var composing: ComposeView.Mode?
    @State private var signOutDecision: SignOutFlow.Decision?

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if let timeline {
                    content(timeline)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Memos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        composing = .create
                    } label: {
                        Image(systemName: "square.and.pencil")
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
        .sheet(item: $composing) { mode in
            if let timeline {
                ComposeView(mode: mode) { content, visibility in
                    await submit(mode, content: content, visibility: visibility, to: timeline)
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
        }
    }

    @ViewBuilder
    private func content(_ timeline: TimelineStore) -> some View {
        List {
            // Session-level notices (a credential that could not be saved, a failed revoke)
            // must survive into the signed-in surface — a warning nobody can see is not one.
            if let notice = session.lastError {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let error = timeline.lastError {
                Text(error).foregroundStyle(.red)
            }
            ForEach(Array(timeline.memos.enumerated()), id: \.element.uid) { index, memo in
                NavigationLink {
                    MemoDetailView(uid: memo.uid, initial: memo, timeline: timeline)
                } label: {
                    MemoRow(memo: memo)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if memo.mine {
                        Button(role: .destructive) {
                            Task {
                                guard let client = session.api else { return }
                                await timeline.delete(uid: memo.uid, using: client)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if memo.mine {
                        Button {
                            Task {
                                guard let client = session.api,
                                    let baseURL = session.serverBaseURL
                                else { return }
                                await timeline.setPinned(
                                    !memo.pinned, uid: memo.uid, using: client, baseURL: baseURL
                                )
                            }
                        } label: {
                            Label(
                                memo.pinned ? "Unpin" : "Pin",
                                systemImage: memo.pinned ? "pin.slash" : "pin"
                            )
                        }
                        .tint(.orange)
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
                    guard timeline.shouldLoadMore(after: index) else { return }
                    guard let client = session.api, let baseURL = session.serverBaseURL else {
                        return
                    }
                    await timeline.loadMore(using: client, baseURL: baseURL)
                }
            }
            if timeline.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await load() }
        .overlay {
            if timeline.memos.isEmpty && !timeline.isLoading {
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
                        Text(option.label)
                    }
                }
            }
        } label: {
            Label("Visibility", systemImage: "eye")
        }
    }

    private func submit(
        _ mode: ComposeView.Mode,
        content: String,
        visibility: MemoVisibility?,
        to timeline: TimelineStore
    ) async -> Bool {
        guard let client = session.api, let baseURL = session.serverBaseURL else { return false }
        switch mode {
        case .create:
            return await timeline.create(
                content: content, visibility: visibility, using: client, baseURL: baseURL
            )
        case .edit(let uid, _):
            return await timeline.edit(uid: uid, content: content, using: client, baseURL: baseURL)
        }
    }

    private func signOut() async {
        signOutDecision = SignOutFlow.decision(for: await session.signOut())
    }

    private func load() async {
        guard let client = session.api, let baseURL = session.serverBaseURL else { return }
        await timeline?.refresh(using: client, baseURL: baseURL)
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

extension MemoVisibility {
    /// The label the SPA uses for the same choice, so the two apps speak one language.
    var label: String {
        switch self {
        case .private: "Private"
        case .protected: "Protected"
        case .public: "Public"
        }
    }
}

struct MemoRow: View {
    let memo: Memo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if memo.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                Text(memo.createdAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if MemoPresentation.hasRenderableBody(memo.content) {
                MemoMarkdownView(content: memo.content)
            }
            if !memo.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(memo.attachments) { attachment in
                            AttachmentThumbnail(attachment: attachment)
                                .frame(height: 120)
                        }
                    }
                }
            }
            if !memo.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(memo.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
