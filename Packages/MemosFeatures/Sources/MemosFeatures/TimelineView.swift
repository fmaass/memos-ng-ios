import MemosCore
import SwiftUI

/// The timeline: one cursor-paginated page at a time, pull to refresh.
public struct TimelineView: View {
    @Environment(SessionStore.self) private var session
    @State private var timeline: TimelineStore?

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
                    Button("Sign out") { Task { await session.signOut() } }
                }
            }
        }
        .task {
            if timeline == nil {
                timeline = TimelineStore(onUnauthorized: { [session] in await session.signOut() })
            }
            await load()
        }
    }

    @ViewBuilder
    private func content(_ timeline: TimelineStore) -> some View {
        List {
            if let error = timeline.lastError {
                Text(error).foregroundStyle(.red)
            }
            ForEach(Array(timeline.memos.enumerated()), id: \.element.uid) { index, memo in
                NavigationLink {
                    MemoDetailView(memo: memo)
                } label: {
                    MemoRow(memo: memo)
                }
                .task {
                    guard timeline.shouldLoadMore(after: index) else { return }
                    guard let client = session.api, let baseURL = session.serverBaseURL
                    else { return }
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

    private func load() async {
        guard let timeline, let client = session.api, let baseURL = session.serverBaseURL else {
            return
        }
        await timeline.refresh(using: client, baseURL: baseURL)
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
