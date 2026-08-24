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

    // Optional for the same reason the timeline's outbox is: a missing environment value must be
    // a screen that does less, never a crash. It is also what lets this screen be HOSTED — the
    // Edit affordance is a toolbar item, and the only way to assert that one is really there is to
    // put the whole screen up and read it back (`MemoEditWiringTests`).
    @Environment(SessionStore.self) private var session: SessionStore?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var playing: VideoPlayback?
    @State private var viewing: MediaViewerSelection?
    @State private var edit = MemoEditFlow()
    @State private var feedback = MemoFeedbackTrigger()
    /// What the zoom transition matches the full-screen viewer to: the picture that was tapped.
    @Namespace private var mediaZoom
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

                // A save that failed used to be a haptic and nothing else: the sheet stayed open
                // and never said why. The store's own message when it has one, a plain sentence
                // when it does not, and only ever after a save actually failed.
                if let failure = edit.lastError {
                    NoticeCard(text: timeline.lastError ?? failure, tone: .error)
                }

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
                        // A picture opens full screen, where it can be zoomed — and grows out of
                        // exactly this frame on the way there.
                        AttachmentThumbnail(attachment: attachment, tier: .mobile, slot: slot)
                            .mediaTransitionSource(id: attachment.uid, in: mediaZoom)
                            .contentShape(.rect)
                            .onTapGesture { open(attachment) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Photo")
                            .accessibilityHint("Opens full screen")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Space.roomy)
        }
        // On the scroll view rather than beside the video cover below: two presentations attached
        // to the SAME view is how one of them silently stops appearing.
        .fullScreenCover(item: $viewing) { selection in
            MediaViewerView(selection: selection)
                .mediaZoomTransition(sourceID: selection.id, in: mediaZoom)
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
        // The only place editing is visible on the memo's own screen. Until this, changing a memo
        // meant knowing to long-press its card back in the timeline — see MemoDetailPresentation.
        .toolbar {
            if let mode = MemoDetailPresentation.editMode(for: memo) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        edit.begin(mode)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit memo")
                }
            }
        }
        .sheet(item: edit.sheet) { mode in
            ComposeView(mode: mode) { submission in
                await edit.submit(submission, save: save)
            }
        }
    }

    /// The same edit the timeline submits, from the screen the memo is already open on.
    private func save(_ mode: ComposeView.Mode, _ submission: ComposeSubmission) async -> Bool {
        guard case .edit(let uid, _, let createdAt) = mode,
            let client = session?.api,
            let baseURL = session?.serverBaseURL
        else { return false }
        let saved = await timeline.edit(
            uid: uid,
            content: submission.content,
            createdAt: MemoDetailPresentation.editedDate(
                chosen: submission.createdAt, original: createdAt
            ),
            using: client,
            baseURL: baseURL
        )
        feedback.fire(saved ? .posted : .postFailed)
        return saved
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

    /// The viewer, opened at the picture that was tapped. A memo carries its other pictures with
    /// it, so the swipe order is the memo's — not just the one photo under the finger.
    private func open(_ attachment: MemoAttachment) {
        viewing = MediaViewerPresentation.viewer(for: memo, startingAt: attachment.uid)
    }

    private func toggle(_ index: Int, to checked: Bool) async {
        guard let client = session?.api, let baseURL = session?.serverBaseURL else { return }
        guard await timeline.toggleTask(at: index, in: uid, using: client, baseURL: baseURL)
        else { return }
        feedback.fire(checked ? .taskChecked : .taskUnchecked)
    }
}
