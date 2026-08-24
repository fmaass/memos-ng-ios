import MemosCore
import SwiftUI

/// One memo, in full — and since Phase 4, the place its checkboxes are ticked.
///
/// The view reads the memo FROM the timeline store rather than keeping the copy it was pushed
/// with: a toggle patches the content, and a detail screen showing the pre-toggle text next to a
/// post-toggle checkbox would be lying about which one the server has. The pushed copy remains
/// only as the fallback for a memo that scrolled out of the loaded window.
public struct MemoDetailView: View {
    let uid: String
    let initial: Memo
    let timeline: TimelineStore

    @Environment(SessionStore.self) private var session
    @State private var playing: VideoPlayback?

    public init(uid: String, initial: Memo, timeline: TimelineStore) {
        self.uid = uid
        self.initial = initial
        self.timeline = timeline
    }

    private var memo: Memo {
        timeline.memos.first { $0.uid == uid } ?? initial
    }

    private var tasks: [(text: String, checked: Bool)] {
        MemoPresentation.tasks(in: memo.content)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(memo.createdAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                MemoMarkdownView(content: memo.content)

                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tasks").font(.headline)
                        ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                            // Someone else's checklist is read: a 403 round trip teaches
                            // nothing a disabled row does not.
                            Button {
                                Task { await toggle(index) }
                            } label: {
                                Label {
                                    Text(task.text)
                                } icon: {
                                    Image(
                                        systemName: task.checked
                                            ? "checkmark.square" : "square"
                                    )
                                }
                                .foregroundStyle(task.checked ? .secondary : .primary)
                            }
                            .buttonStyle(.plain)
                            .disabled(!memo.mine)
                        }
                    }
                }

                ForEach(memo.attachments) { attachment in
                    if let playbackURL = MemoPresentation.playbackURL(for: attachment) {
                        Button {
                            playing = VideoPlayback(url: playbackURL)
                        } label: {
                            AttachmentThumbnail(attachment: attachment, tier: .mobile)
                        }
                        .buttonStyle(.plain)
                    } else {
                        AttachmentThumbnail(attachment: attachment, tier: .mobile)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .fullScreenCover(item: $playing) { playback in
            VideoPlayerView(playback: playback)
        }
        .navigationTitle(memo.pinned ? "Pinned memo" : "Memo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ index: Int) async {
        guard let client = session.api, let baseURL = session.serverBaseURL else { return }
        await timeline.toggleTask(at: index, in: uid, using: client, baseURL: baseURL)
    }
}
