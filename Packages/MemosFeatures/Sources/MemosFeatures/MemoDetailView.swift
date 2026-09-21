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
    @Environment(\.dismiss) private var dismiss
    @State private var viewing: MediaViewerSelection?
    @State private var edit = MemoEditFlow()
    /// How far the conversation about removing ONE of this memo's pictures has got.
    @State private var photoDelete = AttachmentDeleteFlow()
    @State private var exit = MemoDetailExit()
    /// An archive is in flight. The control is disabled while it is, so a second tap cannot ask
    /// for the opposite of what the first one is still doing.
    @State private var isArchiving = false
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
                if let failure = edit.lastError ?? photoDelete.lastError {
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
                // One destination for every attachment: the full-screen viewer, opened on the
                // one that was tapped, growing out of exactly this frame. A video opens there
                // ALREADY PLAYING — a tap on a video means play it — and the memo's other
                // attachments stay one swipe away while it does, which is what a player
                // presented over the pager took away.
                ForEach(memo.attachments) { attachment in
                    picture(attachment)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Space.roomy)
        }
        .fullScreenCover(item: $viewing) { selection in
            // A memo's media is all there when the screen opens and never grows, so the viewer
            // over it pages through a value rather than through a store.
            MediaViewerView(
                selection: selection,
                source: .fixed(selection.pages),
                delete: deletePicture
            )
            .mediaZoomTransition(sourceID: selection.id, in: mediaZoom)
        }
        // The question the gallery's own destructive row asks. It sits on the screen the row is
        // on; the viewer over it asks its own, because an alert under a full-screen cover never
        // appears. An alert rather than a confirmation dialog for the reason
        // `ComposeView.deleteRow` records.
        .alert(
            asked.map { AttachmentDeleteFlow.question(for: $0) } ?? "",
            isPresented: askingDelete,
            presenting: asked
        ) { attachment in
            Button(AttachmentDeleteFlow.title(for: attachment), role: .destructive) {
                sendPictureDelete(.confirmed)
            }
            Button("Cancel", role: .cancel) { sendPictureDelete(.cancelled) }
        } message: { _ in
            Text(AttachmentDeleteFlow.explanation)
        }
        .background(Color(.systemGroupedBackground))
        .scrollEdgeEffectStyle(.soft, for: .top)
        .tint(DesignTokens.accent)
        .sensoryFeedback(trigger: feedback) { _, latest in latest.act?.feedback }
        .navigationTitle(memo.pinned ? "Pinned memo" : "Memo")
        .navigationBarTitleDisplayMode(.inline)
        // The only place editing is visible on the memo's own screen. Until this, changing a memo
        // meant knowing to long-press its card back in the timeline — see MemoDetailPresentation.
        .toolbar {
            // Beside the pencil rather than inside a menu behind it: archiving is a deliberate,
            // reversible act somebody came to this screen to perform, and a second tap to reach it
            // is what made editing undiscoverable before the pencil existed.
            if let action = MemoDetailPresentation.archiveAction(for: memo) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await archive(action) }
                    } label: {
                        Image(systemName: action.symbol)
                    }
                    .disabled(isArchiving)
                    .accessibilityLabel(action.title)
                }
            }
            if let mode = MemoDetailPresentation.editMode(for: memo) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // An editor is opening, so nothing has closed since — whatever the last
                        // one did. See `MemoDetailExit.editorOpened`.
                        exit.editorOpened()
                        edit.begin(mode)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit memo")
                }
            }
        }
        .sheet(item: edit.sheet, onDismiss: { editorDidClose() }) { mode in
            ComposeView(
                mode: mode,
                delete: ComposeDelete(
                    isAsking: edit.deleteStage == .asking,
                    send: { event in
                        Task { await edit.advanceDelete(event, delete: performDelete) }
                    }
                )
            ) { submission in
                await edit.submit(submission, save: save)
            }
        }
        .onChange(of: edit.memoDeleted) { _, gone in
            // The server's answer, which can arrive to an editor that has ALREADY closed: whoever
            // swiped it away while the delete was in flight gets no second `onDismiss`.
            if exit.memoDeletedChanged(gone) { dismiss() }
        }
    }

    /// One of the memo's pictures, at the proportions the server measured — and what can be done
    /// to it.
    ///
    /// The context menu is RENDERED from `attachmentActions(for:)` rather than written out here, so
    /// an affordance that stops being offered, or stops being gated on the memo being mine, is a
    /// failing test rather than a line nobody notices is missing. The same list becomes named
    /// accessibility actions, because a context menu must never be the only way to reach an action
    /// and a long press is not something VoiceOver performs.
    @ViewBuilder
    private func picture(_ attachment: MemoAttachment) -> some View {
        let slot = MemoPresentation.detailSlot(for: attachment)
        let video = attachment.isVideo
        let plays = MemoPresentation.playbackURL(for: attachment) != nil
        let actions = MemoDetailPresentation.attachmentActions(for: memo)
        let tile = AttachmentThumbnail(attachment: attachment, tier: .mobile, slot: slot)
            .mediaTransitionSource(id: attachment.uid, in: mediaZoom)
            .contentShape(.rect)
            .onTapGesture { open(attachment) }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(video ? "Video" : "Photo")
            .accessibilityHint(plays ? "Plays full screen" : "Opens full screen")
        // Nothing to offer is no menu at all: a long press that opens an empty card is worse than
        // one that does nothing.
        if actions.isEmpty {
            tile
        } else {
            tile
                .contextMenu {
                    ForEach(actions) { action in
                        row(action, on: attachment)
                    }
                }
                .accessibilityActions {
                    ForEach(actions) { action in
                        row(action, on: attachment)
                    }
                }
        }
    }

    /// One row of that menu, in whichever shape it is drawn — a menu item, or a named accessibility
    /// action. Both press the SAME thing, so the two cannot come to do different things.
    private func row(_ action: AttachmentAction, on attachment: MemoAttachment) -> some View {
        Button(role: action.isDestructive ? ButtonRole.destructive : nil) {
            perform(action, on: attachment)
        } label: {
            Label(action.title(for: attachment), systemImage: action.symbol)
        }
    }

    private func perform(_ action: AttachmentAction, on attachment: MemoAttachment) {
        switch action {
        case .delete: sendPictureDelete(.tapped(attachment.uid))
        }
    }

    /// The picture a question is open about, or nil.
    private var asked: MemoAttachment? {
        guard let uid = photoDelete.asking else { return nil }
        return memo.attachments.first { $0.uid == uid }
    }

    /// What the alert binds to. Only dismissal comes back through it.
    private var askingDelete: Binding<Bool> {
        Binding(get: { asked != nil }, set: { if !$0 { sendPictureDelete(.cancelled) } })
    }

    /// Every event goes through the flow, and the STATE MOVES HERE — synchronously, before any
    /// task exists.
    ///
    /// The alert's dismissal binding fires in the same turn as the button that dismissed it, so a
    /// confirmation and a cancellation both wrapped in tasks would be two pieces of work with no
    /// order between them: the cancellation running first puts the machine back to `idle` and the
    /// Delete somebody pressed then does nothing at all. Claimed first, the confirmation is
    /// already at `deleting` when the dismissal lands, where a cancellation is the no-op it should
    /// be. Only the REQUEST needs a task.
    private func sendPictureDelete(_ event: AttachmentDeleteFlow.Event) {
        guard photoDelete.claim(event) else { return }
        Task { await photoDelete.perform(delete: deletePicture) }
    }

    /// The request itself. WHEN it runs — once, on the transition into `deleting`, for the picture
    /// that was asked about — is `AttachmentDeleteFlow.advance`'s decision, and the store is what
    /// makes two of them one request on the wire.
    private func deletePicture(_ attachmentUID: String) async -> Bool {
        guard let handle = session?.activeHandle else { return false }
        let deleted = await timeline.deleteAttachment(uid: attachmentUID, from: uid, using: handle)
        feedback.fire(deleted ? .deleted : .postFailed)
        return deleted
    }

    /// The editor has gone from the screen. Whether the memo went with it is the other half, and
    /// `MemoDetailExit` is what holds the two together — the screen leaves on whichever arrives
    /// second, once.
    private func editorDidClose() {
        if exit.editorClosed(memoDeleted: edit.memoDeleted) { dismiss() }
    }

    /// Archives the memo, or takes it back out — and leaves the screen when the list this screen
    /// reads no longer holds it.
    ///
    /// The leaving is decided by asking the store rather than by assuming: a memo archived out of
    /// the plain timeline is gone from it, but the same memo archived while a search for the
    /// archived ones is open is still right there, and popping then would take somebody off a
    /// screen that is still true.
    private func archive(_ action: MemoDetailPresentation.MemoArchiveAction) async {
        guard let handle = session?.activeHandle, let baseURL = session?.serverBaseURL
        else { return }
        isArchiving = true
        defer { isArchiving = false }
        let changed = await timeline.setArchived(
            action.archived, uid: uid, using: handle, baseURL: baseURL
        )
        feedback.fire(changed ? .posted : .postFailed)
        guard changed, !timeline.memos.contains(where: { $0.uid == uid }) else { return }
        dismiss()
    }

    /// The request itself. WHEN it runs — once, on the transition into `deleting`, for the memo
    /// the sheet is open on — is `MemoEditFlow.advanceDelete`'s decision, so that rule lives
    /// somewhere a test can drive rather than inside a view body.
    private func performDelete(_ uid: String) async -> Bool {
        guard let handle = session?.activeHandle else { return false }
        let deleted = await timeline.delete(uid: uid, using: handle)
        feedback.fire(deleted ? .deleted : .postFailed)
        return deleted
    }

    /// The same edit the timeline submits, from the screen the memo is already open on.
    ///
    /// Files picked in the sheet ride along: they are uploaded in the foreground and the memo is
    /// patched with them, whole or not at all (`TimelineStore.edit(attaching:)`). Deliberately not
    /// the outbox, which owns new captures — a queued edit needs an edit key to be retryable, and
    /// that is a separate piece of work.
    private func save(_ mode: ComposeView.Mode, _ submission: ComposeSubmission) async
        -> ComposeOutcome
    {
        guard case .edit(let uid, _, let createdAt, _) = mode,
            let handle = session?.activeHandle,
            let baseURL = session?.serverBaseURL
        else { return .failed(.authorization) }
        let outcome = await timeline.edit(
            uid: uid,
            content: submission.content,
            createdAt: MemoDetailPresentation.editedDate(
                chosen: submission.createdAt, original: createdAt
            ),
            attaching: submission.attachments.map(\.stagedSource),
            using: handle,
            baseURL: baseURL
        )
        feedback.fire(outcome.isSaved ? .posted : .postFailed)
        return outcome
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
                HStack(spacing: DesignTokens.Space.snug) {
                    archived
                    VisibilityPill(visibility: memo.visibility)
                }
            }
        } else {
            HStack(spacing: DesignTokens.Space.snug) {
                OwnerAvatar(owner: memo.owner, size: avatar)
                identity
                Spacer(minLength: DesignTokens.Space.snug)
                archived
                VisibilityPill(visibility: memo.visibility)
            }
        }
    }

    /// The same capsule the card wears, for the same reason: this screen is reachable from a
    /// search that included the archived ones, and nothing else on it would say so.
    @ViewBuilder
    private var archived: some View {
        if memo.isArchived {
            ArchivedPill()
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
        guard let handle = session?.activeHandle, let baseURL = session?.serverBaseURL
        else { return }
        guard await timeline.toggleTask(at: index, in: uid, using: handle, baseURL: baseURL)
        else { return }
        feedback.fire(checked ? .taskChecked : .taskUnchecked)
    }
}

/// Whether the memo's screen has left yet, and on which event it may.
///
/// Two things have to have happened before the screen goes: the server has confirmed the memo is
/// gone, and the editor has actually closed. EITHER can be the second one. The ordinary way round
/// is confirm and wait — the answer arrives, the flow closes the sheet, and the sheet finishing
/// its dismissal is the later event. The other way round is somebody swiping the editor away while
/// the request is still out: `onDismiss` has been and gone by the time the server answers, and the
/// answer is the later event. Acting on only one of them strands the person on the detail view of
/// a memo that no longer exists — the same bug from opposite directions.
///
/// A model rather than two flags in a view body, because "at most one pop, on whichever event is
/// second" is a rule with orders to it, and orders are what a view body cannot be asked about.
@MainActor
@Observable
final class MemoDetailExit {
    /// Whether the editor has closed since it was last opened.
    private(set) var sheetClosed = false
    /// Whether the screen has already left. The second event must not pop a second time.
    private(set) var popped = false

    /// An editor is on screen again, so nothing has closed since. Without this, an editor that was
    /// cancelled would leave `sheetClosed` standing, and the NEXT delete would pop while its own
    /// sheet was still up — which is the swallowed dismissal all over again.
    func editorOpened() {
        sheetClosed = false
    }

    /// The editor has gone from the screen. Answers whether the memo's screen goes now.
    @discardableResult
    func editorClosed(memoDeleted: Bool) -> Bool {
        sheetClosed = true
        return pop(memoDeleted: memoDeleted)
    }

    /// The server has answered about the memo. Answers whether the memo's screen goes now.
    @discardableResult
    func memoDeletedChanged(_ memoDeleted: Bool) -> Bool {
        pop(memoDeleted: memoDeleted)
    }

    private func pop(memoDeleted: Bool) -> Bool {
        let decision = MemoDetailPresentation.popDecision(
            memoDeleted: memoDeleted, sheetClosed: sheetClosed
        )
        guard !popped, decision == .popToOverview else { return false }
        popped = true
        return true
    }
}
