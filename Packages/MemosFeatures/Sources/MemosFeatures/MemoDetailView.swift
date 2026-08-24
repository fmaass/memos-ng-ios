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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var playing: VideoPlayback?
    @State private var feedback = MemoFeedbackTrigger()
    @ScaledMetric(relativeTo: .subheadline) private var avatar = DesignTokens.Metric.avatar

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
            VStack(alignment: .leading, spacing: DesignTokens.Space.roomy) {
                header

                MemoMarkdownView(content: memo.content)

                if !tasks.isEmpty {
                    taskList
                }

                // The detail view is the picture. Each attachment takes the full content width
                // at the proportions the server measured, and the WHOLE frame is shown — nothing
                // is cropped here, whatever the timeline does with the same photo. Because the
                // container takes that shape from the metadata rather than from the decoded
                // image, it is the right size before the download finishes, so the page does not
                // jump and the blurhash sits in exactly the frame the photo will occupy.
                ForEach(memo.attachments) { attachment in
                    let slot = MemoPresentation.detailSlot(for: attachment)
                    if let playbackURL = MemoPresentation.playbackURL(for: attachment) {
                        Button {
                            playing = VideoPlayback(url: playbackURL)
                        } label: {
                            AttachmentThumbnail(
                                attachment: attachment,
                                tier: .mobile,
                                slot: slot
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        AttachmentThumbnail(attachment: attachment, tier: .mobile, slot: slot)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Space.roomy)
        }
        .background(Color(.systemGroupedBackground))
        .scrollEdgeEffectStyle(.soft, for: .top)
        .tint(DesignTokens.accent)
        .sensoryFeedback(trigger: feedback) { _, latest in latest.act?.feedback }
        .fullScreenCover(item: $playing) { playback in
            VideoPlayerView(playback: playback)
        }
        .navigationTitle(memo.pinned ? "Pinned memo" : "Memo")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var header: some View {
        let identity = VStack(alignment: .leading, spacing: 0) {
            Text(MemoCardPresentation.displayName(forOwner: memo.owner))
                .font(.subheadline.weight(.semibold))
            Text(memo.createdAt, format: .dateTime.day().month().year().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
                HStack(spacing: DesignTokens.Space.snug) {
                    OwnerAvatar(owner: memo.owner, size: avatar)
                    identity
                }
                VisibilityPill(visibility: memo.visibility)
            }
        } else {
            HStack(spacing: DesignTokens.Space.snug) {
                OwnerAvatar(owner: memo.owner, size: avatar)
                identity
                Spacer(minLength: DesignTokens.Space.snug)
                VisibilityPill(visibility: memo.visibility)
            }
        }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            Text("Tasks").font(.headline)
            ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                // Someone else's checklist is read: a 403 round trip teaches nothing a disabled
                // row does not.
                Button {
                    Task { await toggle(index, to: !task.checked) }
                } label: {
                    Label {
                        Text(task.text)
                    } icon: {
                        Image(systemName: task.checked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                task.checked
                                    ? AnyShapeStyle(DesignTokens.accent)
                                    : AnyShapeStyle(.secondary)
                            )
                            .symbolEffect(.bounce, value: task.checked)
                    }
                    .foregroundStyle(task.checked ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .disabled(!memo.mine)
            }
        }
    }

    private func toggle(_ index: Int, to checked: Bool) async {
        guard let client = session.api, let baseURL = session.serverBaseURL else { return }
        guard await timeline.toggleTask(at: index, in: uid, using: client, baseURL: baseURL)
        else { return }
        feedback.fire(checked ? .taskChecked : .taskUnchecked)
    }
}
