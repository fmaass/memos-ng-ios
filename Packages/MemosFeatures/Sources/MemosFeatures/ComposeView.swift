import MemosCore
import MemosOutbox
import PhotosUI
import SwiftUI
import UIKit

/// What the compose screen hands back when someone taps Post or Save.
public struct ComposeSubmission: Sendable, Equatable {
    public var content: String
    public var visibility: MemoVisibility?
    public var attachments: [PickedMedia]
    /// The display date the writer asked for, or nil for "whenever this is".
    ///
    /// Nil is not "now" spelled differently: a new capture is stamped when it is written and a
    /// memo being edited keeps the date it already has, and neither of those is a date this sheet
    /// gets to invent. Carrying the absence all the way through is what lets a test tell an
    /// untouched date apart from one that happens to equal the clock.
    public var createdAt: Date?

    public init(
        content: String,
        visibility: MemoVisibility?,
        attachments: [PickedMedia] = [],
        createdAt: Date? = nil
    ) {
        self.content = content
        self.visibility = visibility
        self.attachments = attachments
        self.createdAt = createdAt
    }

    /// What the outbox stamps this capture with: the date the writer chose, or the moment it was
    /// written. It is a function rather than a line inside the view's `submit` so that the one
    /// step where a chosen date could silently be dropped is the one step a test can hold.
    public func capturedAt(now: Date = Date()) -> Date { createdAt ?? now }
}

/// The destructive action an edit sheet offers, and the question it asks first.
///
/// It is handed IN rather than owned for the same reason the save is: the sheet has no store and no
/// client, and one that reached for them would be untestable for exactly that reason. The stage
/// belongs to `MemoEditFlow`; this carries only what the sheet needs to draw — whether the question
/// is up — and where to send the answer.
///
/// Mine-gating is inherent rather than re-checked here: both screens that hand one of these over
/// reach an edit sheet only for a memo that is mine — the memo's own screen opens the sheet solely
/// for `MemoDetailPresentation.editMode`, which is nil otherwise, and the timeline offers Edit
/// inside its `memo.mine` branch alone.
public struct ComposeDelete {
    public var isAsking: Bool
    /// `@MainActor` spelled out: the sink is a method on the screen that presented the sheet, and a
    /// method reference cannot be converted to a non-isolated function type without losing the
    /// isolation it actually has.
    public var send: @MainActor (MemoEditFlow.DeleteEvent) -> Void

    public init(
        isAsking: Bool,
        send: @escaping @MainActor (MemoEditFlow.DeleteEvent) -> Void
    ) {
        self.isAsking = isAsking
        self.send = send
    }
}

/// Writing a memo — new or edited, one screen.
///
/// It is a SHEET with detents: capturing a thought is a half-screen act, and the keyboard is
/// already taking the other half. It opens at `.medium` and grows to `.large` when there is
/// something worth the room.
///
/// Visibility offers "server default" as the unmarked choice on a NEW memo: the account already
/// has an answer for who sees things, and a compose screen that demands the decision every time
/// teaches people to stop reading it. An EDIT never touches visibility here — that is its own
/// deliberate action on the memo, not a side effect of fixing a typo.
///
/// Media comes from two places, both of them originals. The LIBRARY, through the system picker,
/// which exports the file it holds rather than a rendering of it; and the app's own camera
/// (`CameraView`), which writes the photo output's `fileDataRepresentation()` and moves the movie
/// output's file. Neither of them re-encodes anything, and the one obvious way of doing this —
/// `UIImagePickerController` — was rejected for exactly that reason: it hands back a transcoded
/// JPEG for a still the phone took as HEIF. The original is the archive master (ADR-0008).
public struct ComposeView: View {
    public enum Mode: Equatable {
        case create
        /// An edit opens on the memo as it stands, its display date and its pictures included —
        /// the date row is a change to something that already has one, not a blank to fill in,
        /// and the pictures are what the memo has rather than what this sheet has been given.
        case edit(uid: String, content: String, createdAt: Date, attachments: [MemoAttachment])
    }

    let mode: Mode
    let submit: (ComposeSubmission) async -> ComposeOutcome
    /// The destructive action, on an edit that has one. `nil` everywhere else — a new memo has
    /// nothing to delete, and neither has a memo that is not mine (see `ComposeDelete`).
    let delete: ComposeDelete?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // The sheet inherits the session from the screen that presented it; the account's default
    // visibility is the only thing it needs from there.
    @Environment(SessionStore.self) private var session: SessionStore?
    @State private var content: String
    @State private var visibility: MemoVisibility?
    /// The chosen display date, or nil while the capture is simply "now" (an edit starts holding
    /// the memo's own date, so on that path it is never nil).
    @State private var date: Date?
    @State private var picked: [PhotosPickerItem] = []
    /// What the picker has produced, and which pick it belongs to. Choosing again before the
    /// first load has finished is ordinary behaviour, and the older, slower result must not
    /// overwrite the newer — see `ComposeImports`.
    @State private var imports: ComposeImports
    /// The one sentence the sheet has to say: why a Post was refused, or why a Save did not go
    /// through. Never a raw error, and never two at once.
    @State private var problem: String?
    @State private var detent: PresentationDetent = .medium
    /// What the sheet has up — its keyboard and its photo picker — as one value, so the order
    /// between them is a thing a test can hold. See `ComposeStage`.
    @State private var stage = ComposeStage()
    @FocusState private var editorFocused: Bool

    public init(
        mode: Mode,
        delete: ComposeDelete? = nil,
        submit: @escaping (ComposeSubmission) async -> ComposeOutcome
    ) {
        self.init(mode: mode, delete: delete, imports: ComposeImports(), submit: submit)
    }

    /// The same sheet with its import list handed in from outside.
    ///
    /// Internal, and for one reason: what the row does to what is attached can only be asked of
    /// the list the sheet is really holding. A test that built its own beside it would be asking a
    /// different object than the one the row was drawn from.
    init(
        mode: Mode,
        delete: ComposeDelete? = nil,
        imports: ComposeImports,
        submit: @escaping (ComposeSubmission) async -> ComposeOutcome
    ) {
        self.mode = mode
        self.delete = delete
        self.submit = submit
        _imports = State(initialValue: imports)
        _content = State(
            initialValue: {
                if case .edit(_, let content, _, _) = mode { return content }
                return ""
            }())
        _date = State(
            initialValue: {
                if case .edit(_, _, let createdAt, _) = mode { return createdAt }
                return nil
            }())
    }

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// The pictures the memo already has, as the sheet was handed them when it opened.
    ///
    /// A value captured at presentation, like the words and the date beside it: a picture deleted
    /// elsewhere while this sheet is open stays in the row, and saving neither restores it nor
    /// sends anything about it.
    private var existing: [ComposeExisting] {
        guard case .edit(_, _, _, let attachments) = mode else { return [] }
        return attachments.map(ComposeExisting.init(attachment:))
    }

    /// What the row draws, in order — the memo's own pictures first, then what has been picked.
    private var rowItems: [ComposeRowItem] {
        ComposeRow.items(existing: existing, picked: imports.ordered)
    }

    /// A memo with photos and no words is a memo. Only an empty capture is nothing to post.
    ///
    /// It is deliberately NOT the guard for the unresolved items. A disabled button explains
    /// nothing: somebody who has attached a photograph that will not download, and finds Post grey,
    /// is left to guess which of the five things they did was wrong. So the button stays live and
    /// the refusal is a SENTENCE naming the item (`ComposeAttachments.postRefusal`), and the items
    /// that did arrive are never lost in the process.
    private var canSave: Bool {
        ComposeAttachments.canPost(
            text: content,
            imported: imports.attachments.count,
            isBusy: imports.isSubmitting || imports.isImporting
        )
    }

    /// Whether input that changes what is attached may be taken at this instant.
    ///
    /// One rule, asked synchronously wherever such input lands — a picker answering, a camera
    /// handing over a file, a control being pressed — because the list a save carries was fixed
    /// when Save was pressed and a change taken afterwards would be shown on the row and left out
    /// of the upload. It is asked of `imports` rather than of this sheet's own state because that
    /// object is what every one of those changes is about: the question and the change that
    /// follows it are then one synchronous pair on the same object, and every closure that can
    /// bring such input in holds that object itself.
    private var mayChangeAttachments: Bool { imports.acceptsChanges }

    /// The date this memo will carry: the one that was chosen, or — while the control is on Auto —
    /// the earliest capture instant among what is attached. Nil is "whenever this is", which the
    /// outbox stamps with the moment of writing.
    private var resolvedDate: Date? { ComposeDate.resolved(chosen: date, auto: auto) }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                editor
                Divider()
                controls
            }
            .navigationTitle(isEdit ? "Edit memo" : "New memo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEdit ? "Save" : "Post") { post() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .task {
                stage.opened()
                // Applied here as well as through the change handler below. The first raise is
                // what decides whether this screen opens ready to be written in, and it must not
                // rest on a handler having been installed before this task ran.
                editorFocused = stage.wantsKeyboard
            }
            // Both directions on purpose. The stage raises and lowers the keyboard, but focus also
            // moves without being asked — a tap into the editor, a drag that dismisses the
            // keyboard — and a stage that missed those would believe the keyboard already down the
            // next time the picker is asked for, lower nothing, and let the picker open over a
            // standing keyboard exactly as it did before.
            .onChange(of: editorFocused) { _, focused in stage.editorFocusChanged(to: focused) }
            .onChange(of: stage.wantsKeyboard) { _, wants in editorFocused = wants }
            // The keyboard's own signals carry its PRESENCE — will-show the moment it starts
            // arriving, did-hide only when the resignation has FINISHED and the sheet's geometry
            // is done following it. The picker's presentation waits on these, never on focus,
            // which can be gone while the keyboard is still moving (ComposeStage).
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillShowNotification
                )
            ) { _ in stage.keyboardShown() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardDidHideNotification
                )
            ) { _ in stage.keyboardHidden() }
        }
        .tint(DesignTokens.accent)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        // The picker, presented by the sheet itself rather than by the pill.
        //
        // A `PhotosPicker` control has no moment of its own between the tap and the presentation,
        // and that moment is where the keyboard has to go down — see `ComposeStage`. As a modifier
        // the presentation also stops being something the meta row carries: the row is a
        // `ViewThatFits` that builds a candidate for each of five spellings, so a presentation
        // source written into the pill is built five times over for one that is placed.
        .photosPicker(
            isPresented: pickingPhotos,
            selection: $picked,
            selectionBehavior: .ordered,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        // The other source, presented the same way and for the same reason: it is asked for from
        // the pill and only ever closed through this binding.
        .fullScreenCover(isPresented: capturingCamera) {
            CameraView(capture: CameraCapture { media in imports.captured(media) })
        }
    }

    /// A prompt rather than an empty grey rectangle. `TextEditor` has no placeholder, so it is one
    /// overlay, and it is `allowsHitTesting(false)` so tapping the words still lands in the field.
    private var editor: some View {
        TextEditor(text: $content)
            .focused($editorFocused)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, DesignTokens.Space.regular)
            .padding(.top, DesignTokens.Space.snug)
            .overlay(alignment: .topLeading) {
                if content.isEmpty {
                    Text("What happened?")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, DesignTokens.Space.roomy)
                        .padding(.top, DesignTokens.Space.regular)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Everything under the editor: what is attached, who will see it, and when it happened.
    ///
    /// The meta row is LAST, and everything that can appear — the thumbnails, the notice about
    /// files that would not read — is above it. The row's own bottom edge is the sheet's, so
    /// nothing arriving above it can move it: attaching a photo grows the block upwards into the
    /// editor's space and the three pills stay exactly where they were.
    ///
    /// An EDIT shows the date and the photo picker, and not the visibility — who can see a memo is
    /// its own deliberate action (see the type comment), while a wrong date is a typo like any
    /// other and a photograph left out of a memo is exactly the thing somebody reopens it to fix.
    ///
    /// The files an edit picks go up in the FOREGROUND and the memo is patched with them directly
    /// (`TimelineStore.edit(attaching:)`), rather than through the outbox that owns new captures:
    /// without an edit key a queued retry cannot be made safe, so an edit is something that
    /// happens while its sheet is open or does not happen at all.
    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            attachedRow
            if !isEdit {
                metaRow
            } else {
                editRow
                if let delete {
                    deleteRow(delete)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.regular)
        .onChange(of: picked) { _, items in
            // Which of the three things an answer here can be is decided on the stage, because
            // the emptying this sheet does to refuse one is itself an answer and arrives later —
            // possibly after the save it was refused for has ended (`ComposeStage`).
            // The stage is told whether this sheet is taking changes to what is attached at all.
            // It is not, while a save is on the wire and afterwards while one that may have
            // reached the server is unanswered for — and a selection that lands then is refused
            // and emptied rather than loaded, which is what leaves the sentence about that save on
            // the screen (`ComposeImports.acceptsChanges`).
            switch stage.selectionLanded(
                count: items.count, submitting: !imports.acceptsChanges
            ) {
            case .swallowReset:
                return
            case .refuseAndReset:
                picked = []
                return
            case .load:
                break
            }
            // Stamped HERE, synchronously, as the selection lands — not inside the task, where
            // the number would order the loads' start times instead. See `ComposeImports`.
            let stamp = imports.selected()
            problem = nil
            Task {
                await imports.load(items, stamp: stamp) { item in
                    do {
                        guard let media = try await item.loadTransferable(type: PickedMedia.self)
                        else {
                            // The picker answered, with nothing. That is not a network fact, so it
                            // is not allowed to say "needs connection".
                            return .failed(.unknown)
                        }
                        return .file(media)
                    } catch {
                        return .failed(ComposeLoadFailure.category(for: error))
                    }
                }
            }
        }
        .onChange(of: imports.items.count) { _, _ in
            // The sentence was about the list as it was.
            problem = nil
        }
        .onChange(of: imports.attachments.isEmpty) { _, isEmpty in
            // Photos are the reason to want the room; the sheet takes it rather than making
            // someone drag it open to see what they just attached.
            if !isEmpty { detent = .large }
        }
    }

    /// The memo's pictures and what would not read. Shared by both modes: a file the picker
    /// cannot export is the one thing that must never pass quietly, whether it was picked for a
    /// new memo or added to one that already exists.
    @ViewBuilder
    private var attachedRow: some View {
        if !rowItems.isEmpty {
            PickedThumbnailRow(
                items: rowItems,
                // A tile offering "Try again" is still on screen in the frame Save is pressed:
                // the marks the last attempt left are cleared as the submission is claimed
                // (`ComposeImports.beginPostAttempt`) and the row redraws a frame later, so the
                // tap that beat the redraw reaches this. This is only a hint — it saves starting
                // work that would be refused. The fence is in `ComposeImports.retry`, where the
                // writing happens, because what is asked here is asked at the tap and what it
                // asks about is true at the tap: a retry can wait behind a Save pressed after it.
                retry: { id in
                    guard mayChangeAttachments else { return }
                    Task { await imports.retry(id: id) }
                },
                // Only what this sheet picked. The memo's own pictures are drawn by the same row
                // and are not this sheet's to take away (`ComposeRowItem`).
                //
                // And only while nothing is on the wire. The submission is built when Save is
                // pressed, so a tile that leaves the row after that is a picture the upload still
                // carries: it goes up, the sheet closes, and the memo keeps the very thing
                // somebody had just taken off it. So the removal is REFUSED for as long as a save
                // is running — pressing it again once the save has come back is the way to make
                // it stick — and the refusal is here, on the same flag the save claims
                // synchronously (`post()`), because a control that has gone grey is a hint and
                // the tap that beat the redraw is the one that does the damage.
                remove: { id in
                    guard mayChangeAttachments else { return }
                    imports.remove(id: id)
                })
        }
        if imports.failed > 0,
            let summary = ComposeAttachments.summary(
                imported: imports.attachments.count, failed: imports.failed
            )
        {
            HStack(spacing: DesignTokens.Space.snug) {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                // Only the failed ones. The successful imports and the camera captures are not
                // what anybody is asking to be rid of.
                Button("Remove them") { imports.removeFailed() }
                    .font(.footnote)
            }
        }
        if let problem {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// An edit's two controls: what to add, and when the memo happened.
    ///
    /// Two pills rather than the capture row's three, and the same discipline: nothing arrives or
    /// leaves as the state changes, and `ViewThatFits` drops what each pill SAYS rather than
    /// reflowing the row, so the last spelling is a promise that it fits at any text size.
    private var editRow: some View {
        ViewThatFits(in: .horizontal) {
            editPills(.short)
            editPills(.glyph)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editPills(_ spelling: ComposeMetaRow.Spelling) -> some View {
        HStack(spacing: DesignTokens.Space.snug) {
            PhotosPickerPill(
                stage: $stage,
                count: imports.attachments.count,
                isImporting: imports.isImporting,
                spelling: spelling
            )
            // Not clearable and never Auto: a memo being edited already has a date, and the
            // files already on it carry no capture instant this client has ever read. Edit Auto is
            // its own ticket.
            MemoDateRow(date: $date, clearable: false, spelling: spelling)
        }
    }

    /// The three things a capture carries besides its words: what is attached, when it happened,
    /// and who will see it. Always three pills, always in that order, always on one line.
    ///
    /// The row this replaced grew and shrank CONTROLS. A ✕ appeared beside the date once one was
    /// chosen, a spinner appeared beside the picker while photos loaded, and the "Add photos or
    /// videos" button moved every time — people reported it as the button jumping, which is
    /// exactly what it was. Something ARRIVING in a row is what makes the thing next to it move,
    /// so nothing arrives any more: the pills are always all three, and the only thing that gives
    /// when the text gets large is how much each of them spells out.
    ///
    /// `ViewThatFits` walks `ComposeMetaRow.Verbosity.allCases` widest-first and takes the first
    /// that fits the sheet. The last one is glyphs alone, and `DynamicTypeFittingTests` holds it
    /// to fitting at `.accessibility5` — that is what makes "the row never reflows" a fact rather
    /// than a hope.
    private var metaRow: some View {
        ViewThatFits(in: .horizontal) {
            pills(.full)
            pills(.plain)
            pills(.quiet)
            pills(.glyphs)
            pills(.bare)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one destructive thing this sheet can do, and the question it asks first.
    ///
    /// An ALERT rather than a confirmation dialog, for the reason the sign-out flow discovered the
    /// hard way: the dialog rendered as a glass card that dimmed nothing and put its Cancel button
    /// neither on screen nor in the accessibility tree, so the only visible answer to a
    /// destructive question was "yes". An alert dims, shows both answers, and hands both to
    /// VoiceOver.
    ///
    /// The alert lives HERE, inside the sheet, rather than on the screen that presented it: an
    /// alert attached to a view with a sheet over it is the classic way to make a presentation
    /// silently never appear.
    private func deleteRow(_ delete: ComposeDelete) -> some View {
        Button(role: .destructive) {
            delete.send(.tapped)
        } label: {
            Label("Delete memo", systemImage: "trash")
                .font(.footnote.weight(.medium))
        }
        .buttonStyle(.borderless)
        // The destructive role reddens the WORDS; the glyph beside them is drawn in the inherited
        // tint, which is this app's green — so the one row that should read as dangerous had a
        // friendly icon on it.
        .tint(.red)
        .alert(
            "Delete this memo?",
            isPresented: .init(
                get: { delete.isAsking },
                set: { if !$0 { delete.send(.cancelled) } }
            )
        ) {
            Button("Delete", role: .destructive) { delete.send(.confirmed) }
            Button("Cancel", role: .cancel) { delete.send(.cancelled) }
        } message: {
            Text(
                "It is removed from the server, with anything attached to it."
                    + " This cannot be undone."
            )
        }
    }

    private func pills(_ verbosity: ComposeMetaRow.Verbosity) -> some View {
        ComposeMetaPills(
            verbosity: verbosity,
            stage: $stage,
            attachmentCount: imports.items.count,
            isImporting: imports.isImporting,
            date: $date,
            auto: auto,
            visibility: $visibility,
            accountDefault: session?.defaultVisibility
        )
    }

    /// What the Auto side of the date control has to say, or nil on an edit, which has no Auto.
    private var auto: AutoMemoDateResult? {
        ComposeDate.auto(isEdit: isEdit, from: imports.autoDate)
    }

    /// Post, or say why not.
    ///
    /// The refusal is checked HERE rather than in the button's `disabled`, and it is checked again
    /// on every tap: an item can settle, fail or be removed between two taps, and the answer to
    /// "may this go now" is only ever about the list as it stands. The submission is claimed
    /// synchronously, before any await, so two taps in one frame are one submission — a disabled
    /// button is not the guard for that either — and the same claim is what every attachment
    /// control is then refused on (`mayChangeAttachments`).
    private func post() {
        guard !imports.isSubmitting else { return }
        // The marks the LAST attempt left are cleared before this attempt is judged — otherwise a
        // save that failed on transport can never be tried again (`ComposeImports.beginPostAttempt`).
        if let refusal = imports.beginPostAttempt() {
            problem = refusal
            return
        }
        problem = nil
        imports.beginSubmission()
        Task {
            defer { imports.endSubmission() }
            let submission = ComposeSubmission(
                content: content,
                visibility: visibility,
                attachments: imports.attachments,
                createdAt: resolvedDate
            )
            let outcome = await submit(submission)
            switch outcome {
            case .saved:
                dismiss()
            case .failed(let failure):
                // The sheet stays open with everything still in it — the words, the date mode, the
                // files and their identities. That is the whole of what "preserved" means here: it
                // is THIS compose session, not survival across a dismissal or a force-quit, which
                // would need the outbox and is MEMNG-124's line.
                problem = ComposeFailurePresentation.sentence(for: failure)
                // These two are the answers that left a request the server may have applied, and
                // from here what is attached may not change: a different set mints a different
                // edit key, the server's replay lookup misses, and the files go up a second time
                // beside the ones it already holds (`ComposeImports.mayHaveLanded`). Read off the
                // failure itself, never off the tile category, which the answers that reached
                // nothing share.
                switch failure {
                case .transport(sent: true), .serverFailure: imports.mayHaveLandedOnServer()
                case .transport(sent: false), .authorization, .storage, .rejection: break
                }
                if let category = ComposeFailurePresentation.tileCategory(for: failure) {
                    imports.markUploadFailed(category)
                }
            }
        }
    }

    /// What the picker's presentation binds to. Only dismissal comes back through it — the picker
    /// is opened by the pill and never by an assignment from outside, the same discipline
    /// `MemoEditFlow.sheet` is built on.
    private var pickingPhotos: Binding<Bool> {
        Binding(get: { stage.pickingPhotos }, set: { if !$0 { stage.photosPickerClosed() } })
    }

    /// The camera's presentation, on the same discipline as the picker's.
    private var capturingCamera: Binding<Bool> {
        Binding(get: { stage.capturing }, set: { if !$0 { stage.cameraClosed() } })
    }
}

/// Who will see it, as a pill that opens a menu.
///
/// It replaces a segmented control, which had four segments that each had to be short enough to
/// fit a quarter of the screen — so at any accessibility text size the words became stumps. A
/// menu shows one choice at a time, at whatever width that choice needs.
struct VisibilityMenu: View {
    @Binding var selection: MemoVisibility?
    var accountDefault: MemoVisibility?
    /// How much the PILL says. The menu itself always spells everything out.
    var spelling: ComposeMetaRow.Spelling = .spelledOut

    var body: some View {
        Menu {
            Picker("Visibility", selection: $selection) {
                // The MENU always spells it out: a row you are choosing between has to say what
                // it is, however little the pill needs to.
                Label(
                    accountDefault.map { "Default (\($0.label))" } ?? "Default",
                    systemImage: VisibilityChoice.symbol(
                        selection: nil, accountDefault: accountDefault
                    )
                )
                .tag(MemoVisibility?.none)
                ForEach(MemoVisibility.allCases, id: \.self) { option in
                    Label(option.label, systemImage: option.symbolName)
                        .tag(MemoVisibility?.some(option))
                }
            }
        } label: {
            VisibilityChoicePill(
                selection: selection, accountDefault: accountDefault, spelling: spelling
            )
        }
        // The MENU is the element VoiceOver lands on, and a label here replaces whatever the pill
        // inside says — so this is the one that has to name the resolved visibility. Without it
        // the icon-only public state would announce itself as the bare word "Visibility".
        .accessibilityLabel(
            VisibilityChoice.accessibilityLabel(
                selection: selection, accountDefault: accountDefault
            )
        )
    }
}

/// The label of the visibility menu — extracted so its fit at the largest text size can be
/// measured directly (`DynamicTypeFittingTests`) rather than eyeballed in a screenshot.
struct VisibilityChoicePill: View {
    let selection: MemoVisibility?
    var accountDefault: MemoVisibility?
    /// The MOST this pill may say. The text size can still shorten it below that — a spelling the
    /// row picked because it fits at one size must not be honoured into running off the screen at
    /// another.
    var spelling: ComposeMetaRow.Spelling = .spelledOut

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var title: String? {
        guard spelling != .glyph else { return nil }
        return VisibilityChoice.title(
            selection: selection,
            accountDefault: accountDefault,
            compact: spelling == .short || dynamicTypeSize.isAccessibilitySize
        )
    }
    var symbol: String {
        VisibilityChoice.symbol(selection: selection, accountDefault: accountDefault)
    }

    var body: some View {
        MetaPill(symbol: symbol, title: title, isSet: selection != nil)
            .accessibilityLabel(
                VisibilityChoice.accessibilityLabel(
                    selection: selection, accountDefault: accountDefault
                )
            )
    }
}

/// What the visibility control says it will do.
///
/// "Default" on its own is the one answer that tells nobody anything: the whole question is who
/// will see this, and leaving the choice alone is only safe if you know what leaving it alone
/// means. So the account's own setting is named alongside it — and when the app does not know
/// that setting yet, it says "Default" rather than inventing one, because a wrong promise about
/// who can read a memo is worse than a vague one.
enum VisibilityChoice {
    /// What will actually happen to this memo: the explicit choice, or the account's setting when
    /// there is no explicit choice. `nil` only while the app has not been told the setting.
    static func resolved(
        selection: MemoVisibility?,
        accountDefault: MemoVisibility?
    ) -> MemoVisibility? {
        selection ?? accountDefault
    }

    /// The word on the pill, or `nil` when the globe says it alone.
    ///
    /// Public gets no word for the same reason it gets none on a card: it is what nearly every
    /// memo is, so the word never distinguishes anything. That covers BOTH ways of arriving at
    /// public — chosen outright, or inherited from the account — and the two are deliberately not
    /// told apart here. For this memo they mean the identical thing, the menu's checkmark still
    /// shows which row is active, and inventing a visual difference for a distinction with no
    /// consequence is how a control starts looking like it is saying something it is not.
    ///
    /// `compact` drops the framing and keeps the answer. At an accessibility text size
    /// "Default (Protected)" wants 518pt of the 369 a compose sheet has, and a pill that refuses
    /// to truncate would simply run off the screen — so at those sizes it says "Protected", which
    /// is the part that was worth saying.
    static func title(
        selection: MemoVisibility?,
        accountDefault: MemoVisibility?,
        compact: Bool = false
    ) -> String? {
        if resolved(selection: selection, accountDefault: accountDefault) == .public {
            return nil
        }
        if let selection { return selection.label }
        guard let accountDefault else { return "Default" }
        return compact ? accountDefault.label : "Default (\(accountDefault.label))"
    }

    static func symbol(selection: MemoVisibility?, accountDefault: MemoVisibility?) -> String {
        resolved(selection: selection, accountDefault: accountDefault)?.symbolName
            ?? "person.crop.circle"
    }

    /// What a screen reader hears, which is never abbreviated and never icon-only. The pill can
    /// drop a word; the app may not drop the fact.
    static func accessibilityLabel(
        selection: MemoVisibility?,
        accountDefault: MemoVisibility?
    ) -> String {
        guard let resolved = resolved(selection: selection, accountDefault: accountDefault) else {
            return "Visibility: the account default"
        }
        return selection == nil
            ? "Visibility: \(resolved.label), the account default"
            : "Visibility: \(resolved.label)"
    }
}

/// When the memo happened, as one pill that opens a picker.
///
/// A capture is dated the moment it is written, and that is right almost every time — so the pill
/// starts as a bare calendar glyph and costs nothing to ignore. Tapping it opens the platform's
/// own date picker; changing anything there is what actually chooses a date, so opening the picker
/// out of curiosity does not silently backdate a memo. Putting it back to the time of writing is
/// inside the picker, not beside the pill: a control that appears next to another one is a control
/// that moves it.
///
/// There is no upper bound on what can be chosen. The web app's own picker sets none and the
/// server stores what it is given, and a client that quietly refused a date the other client
/// accepts would be the odd one out rather than the careful one.
struct MemoDateRow: View {
    @Binding var date: Date?
    /// What Auto has worked out from the attached files, or nil where there is no Auto — an edit.
    /// It is passed in rather than computed here because the answer belongs to the attachments,
    /// and a control that went looking for them would be a control no test could pose a question
    /// to.
    var auto: AutoMemoDateResult?
    /// Whether "no date of its own" is still available. It is the default for a new capture; a
    /// memo being edited already has a date, and there is nothing to clear it back to.
    var clearable: Bool = true
    /// Whether the pill carries the date beside its glyph.
    var spelling: ComposeMetaRow.Spelling = .short

    @State private var isPicking = false
    /// What the picker opens on when nothing has been chosen. Captured when the picker opens
    /// rather than read inside `body`, which would move it on every redraw.
    @State private var seed = Date()

    var body: some View {
        Button {
            seed = date ?? Date()
            isPicking = true
        } label: {
            MemoDatePill(date: date, auto: auto, spelling: spelling)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Memo date")
        .accessibilityValue(MemoDateChoice.spokenValue(for: date, auto: auto))
        .popover(isPresented: $isPicking) {
            MemoDatePicker(date: $date, seed: seed, clearable: clearable, isAuto: auto != nil) {
                isPicking = false
            }
            // A popover rather than the sheet iOS would otherwise substitute on a phone: the
            // compose sheet is already a sheet, and a second one over it hides the memo being
            // dated behind the picker that dates it.
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// The calendar the date pill opens.
///
/// The WIDTH is why this is its own view rather than three modifiers at the call site. A graphical
/// `DatePicker` has no width of its own: asked what it wants it answers zero (measured: 24pt, the
/// padding alone), and asked for everything it takes everything. A popover sizes itself to what
/// its content asks for — so the picker SHIPPED as a 68-point sliver showing one column of the
/// calendar, with the month header cut to "26 >" and no way to pick a date at all. The frame is
/// the fix, and `DynamicTypeFittingTests` holds it.
struct MemoDatePicker: View {
    @Binding var date: Date?
    /// What the picker opens on when no date has been chosen — passed in, so that merely LOOKING
    /// at the picker does not date the memo.
    let seed: Date
    var clearable: Bool = true
    /// Whether clearing the date puts the control back on AUTO (a new memo) rather than on the
    /// time of writing. It changes only what the button SAYS: what it does — putting the chosen
    /// date back to nothing — is one act, and nil has meant "this sheet chose no date" all along.
    var isAuto: Bool = false
    var onDone: () -> Void = {}

    /// The picker edits this rather than `date` directly, so that "no date chosen" survives merely
    /// looking at the picker: the memo takes a date when the picker's value MOVES.
    ///
    /// A move onto another DAY also closes the picker. That tap is what the pill was opened for,
    /// and a calendar that stayed up once it had been answered read as though the tap had done
    /// nothing — the pill it dated is behind the popover. A move that only changes the time keeps
    /// the picker up: the hour and minute are edited in place under the calendar, and a picker
    /// that went away on every tick of the wheel would be a time nobody could set. Internal rather
    /// than private because driving this binding is the tap on the calendar (`ComposeDateTests`).
    var chosen: Binding<Date> {
        Binding(
            get: { self.date ?? self.seed },
            set: { moved in
                let shown = self.date ?? self.seed
                self.date = moved
                if !Calendar.current.isDate(moved, inSameDayAs: shown) { self.onDone() }
            }
        )
    }

    /// The calendar's own width. A number rather than a `@ScaledMetric` because the control is a
    /// UIKit date picker that lays out at the same size whatever the text size — measured 390pt
    /// tall at both `.large` and `.accessibility5` — so scaling this would only pad the popover.
    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            DatePicker(
                "Memo date",
                selection: chosen,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            if clearable {
                Button {
                    date = nil
                    onDone()
                } label: {
                    Label(
                        isAuto ? "Auto" : "Now",
                        systemImage: isAuto ? "wand.and.sparkles" : "clock"
                    )
                    .font(.subheadline)
                }
                .disabled(date == nil)
                .accessibilityLabel(
                    isAuto ? "Use the date of the photographs" : "Use the time of writing")
            }
        }
        .frame(width: Self.width)
        .padding(DesignTokens.Space.regular)
    }
}

/// The date row's label — extracted so its fit at the largest text size is measured directly
/// (`DynamicTypeFittingTests`), the same way the visibility pill is.
struct MemoDatePill: View {
    let date: Date?
    /// The Auto answer, on a sheet that has one. A pill with no chosen date and no Auto is the old
    /// "Now" pill, which is what an edit's date row still is.
    var auto: AutoMemoDateResult?
    var spelling: ComposeMetaRow.Spelling = .short

    var title: String? {
        guard spelling != .glyph else { return nil }
        if date == nil, let auto { return MemoDateChoice.autoTitle(auto) }
        return MemoDateChoice.pillTitle(for: date)
    }

    var body: some View {
        MetaPill(symbol: "calendar", title: title, isSet: date != nil)
    }
}

/// What the date row says.
nonisolated enum MemoDateChoice {
    /// `compact` keeps the day and the month and drops the year and the time. At an accessibility
    /// text size the full date wants more width than a compose sheet has, and a pill that refuses
    /// to truncate would run off the screen — so it says the part that answers "when", and the
    /// picker behind it still shows the whole date. (The same trade the visibility pill makes.)
    static func title(
        for date: Date?,
        compact: Bool = false,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let date else { return "Now" }
        let style: Date.FormatStyle =
            compact
            ? .dateTime.day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year().hour().minute()
        return date.formatted(style.locale(locale))
    }

    /// What the pill says while the control is on AUTO: the date the photographs decided, marked
    /// approximate when the winning one carried no offset of its own, with the span when they were
    /// not all taken on one day.
    ///
    /// "Auto · now" is the honest answer for a memo with nothing dated attached: Auto is on, and
    /// what it resolves to is the moment of writing. It does not show a date this sheet invented.
    ///
    /// The "≈" is the ONLY surface of approximation anywhere — an exact instant and a resolved
    /// civil one compete on equal terms, and the tilde is what says the winner was the second kind.
    static func autoTitle(
        _ auto: AutoMemoDateResult,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        var text = "Auto · "
        if let instant = auto.instant {
            if auto.approximate { text += "≈ " }
            text += title(for: instant, compact: true, locale: locale)
        } else {
            text += "now"
        }
        if auto.span > 0 { text += " · spans \(auto.span) days" }
        return text
    }

    /// What a screen reader hears on the date control, which never abbreviates and never leaves the
    /// mode unsaid.
    static func spokenValue(
        for date: Date?,
        auto: AutoMemoDateResult?,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard date == nil, let auto else { return title(for: date, locale: locale) }
        guard let instant = auto.instant else { return "Automatic: the time of writing" }
        let stamp = title(for: instant, locale: locale)
        let approximately = auto.approximate ? "approximately " : ""
        let span = auto.span > 0 ? ", spanning \(auto.span) days" : ""
        return "Automatic: \(approximately)\(stamp)\(span)"
    }

    /// What the PILL carries beside its calendar, or nil while the capture is simply "now".
    ///
    /// Nil rather than the word "Now" because the glyph already says it: a row of three pills has
    /// room for the answers that differ from the default, and no room for the ones that do not.
    /// And always the SHORT form — the whole date is in the picker behind it and in what a screen
    /// reader hears (`accessibilityValue`), so spelling it out here would only cost the row its
    /// other two pills.
    static func pillTitle(for date: Date?, locale: Locale = .autoupdatingCurrent) -> String? {
        guard date != nil else { return nil }
        return title(for: date, compact: true, locale: locale)
    }
}

// MARK: - the meta row

/// The compose sheet's meta row, as a model rather than a layout.
///
/// It exists so that "the row is always these three, in this order, and this is the least it can
/// say" is something a test can hold, rather than something a body happens to do this week.
nonisolated public enum ComposeMetaRow {
    /// How much a pill says beside its glyph.
    public enum Spelling: Sendable, Equatable {
        /// The glyph alone.
        case glyph
        /// The short answer: a day and a month, a count, a single word.
        case short
        /// The whole thing, framing included ("Default (Protected)").
        case spelledOut
    }

    /// The spellings the row tries, WIDEST FIRST. `ViewThatFits` takes the first that fits, so the
    /// last one is a promise: it has to fit at any text size, in any locale, on the narrowest
    /// phone. Nothing here changes the ORDER or the NUMBER of pills — only how much each says.
    public enum Verbosity: CaseIterable, Sendable {
        /// Count, short date, and the visibility spelled out with its framing.
        case full
        /// Count, short date, and the visibility as a single word.
        case plain
        /// Count, short date, and the visibility as its glyph.
        case quiet
        /// Count, and both of the others as glyphs.
        case glyphs
        /// Three glyphs. The fallback that must always fit.
        case bare

        public var count: Spelling { self == .bare ? .glyph : .short }
        public var date: Spelling { self == .glyphs || self == .bare ? .glyph : .short }
        public var visibility: Spelling {
            switch self {
            case .full: .spelledOut
            case .plain: .short
            case .quiet, .glyphs, .bare: .glyph
            }
        }
    }

    /// The number beside the photo glyph, or nil when there is nothing attached — an empty pill is
    /// the invitation to attach something, and a "0" is noise.
    public static func photosTitle(count: Int) -> String? {
        count > 0 ? count.formatted() : nil
    }

    /// What a screen reader hears on the photos pill. Never a bare number: the count is only half
    /// the fact, and the other half is that tapping it opens the picker.
    public static func photosAccessibilityLabel(count: Int, isImporting: Bool) -> String {
        if isImporting { return "Adding photos or videos" }
        switch count {
        case 0: return "Add photos or videos"
        case 1: return "1 photo or video attached. Add photos or videos"
        default: return "\(count) photos or videos attached. Add photos or videos"
        }
    }

    /// The two places media comes from, as the pill's menu names them.
    ///
    /// A MENU on the existing pill rather than a fourth pill in the row. The row is exactly its
    /// three pills at every text size — `DynamicTypeFittingTests` holds both halves of that, the
    /// all-glyph fallback fitting a 369pt sheet and the row measuring the sum of its three — and a
    /// fourth glyph does not fit at the accessibility sizes. It is also the truer shape: attaching
    /// media is ONE intention with two sources, the way the visibility pill beside it is one
    /// question with three answers.
    public static let libraryChoice = "Photo library"
    public static let cameraChoice = "Camera"

    /// The order the menu shows those two in: the declared one, top to bottom.
    ///
    /// Left to itself, a menu that is not inside scrollable content orders by PRIORITY on iOS —
    /// the first item is kept nearest the point of interaction. This pill sits at the bottom of
    /// the sheet, over the keyboard, so its menu opens upward, and priority put the library —
    /// declared first — at the bottom, under the camera. Fixed order is what the declaration
    /// says, wherever the menu opens.
    public static let photoChoicesOrder: MenuOrder = .fixed
}

/// The three pills, in the one order they are ever in.
///
/// Its width is exactly its three pills and the two gaps between them, which is what lets a test
/// assert that nothing else has crept into the row.
struct ComposeMetaPills: View {
    let verbosity: ComposeMetaRow.Verbosity
    @Binding var stage: ComposeStage
    let attachmentCount: Int
    var isImporting: Bool = false
    @Binding var date: Date?
    var auto: AutoMemoDateResult?
    @Binding var visibility: MemoVisibility?
    var accountDefault: MemoVisibility?

    var body: some View {
        HStack(spacing: DesignTokens.Space.snug) {
            PhotosPickerPill(
                stage: $stage,
                count: attachmentCount,
                isImporting: isImporting,
                spelling: verbosity.count
            )
            MemoDateRow(date: $date, auto: auto, spelling: verbosity.date)
            VisibilityMenu(
                selection: $visibility,
                accountDefault: accountDefault,
                spelling: verbosity.visibility
            )
        }
    }
}

/// The photos pill, which offers the two places media comes from: the library, and the camera.
///
/// It replaced an "Add photos or videos" button that sat apart from the meta row and moved whenever
/// anything in that row changed, and it is a MENU for the reason given on
/// `ComposeMetaRow.libraryChoice` — the row is three pills wide at every text size, and this is one
/// intention with two sources rather than two intentions.
///
/// Either way it ASKS rather than presents. A `PhotosPicker` control goes straight from the tap to
/// the presentation, leaving nowhere to put the keyboard down first — which is the moment the
/// flicker lived in (see `ComposeStage`) — and a full-screen camera arriving over a settling sheet
/// is the same defect. Both presentations are modifiers on the sheet; this is what reaches them.
struct PhotosPickerPill: View {
    @Binding var stage: ComposeStage
    let count: Int
    var isImporting: Bool = false
    var spelling: ComposeMetaRow.Spelling = .short

    var body: some View {
        Menu {
            Button {
                stage.pickPhotos()
            } label: {
                Label(ComposeMetaRow.libraryChoice, systemImage: "photo.on.rectangle.angled")
            }
            Button {
                stage.openCamera()
            } label: {
                Label(ComposeMetaRow.cameraChoice, systemImage: "camera")
            }
        } label: {
            PhotosPill(count: count, isImporting: isImporting, spelling: spelling)
        }
        .menuOrder(ComposeMetaRow.photoChoicesOrder)
        // The MENU is what VoiceOver lands on, and a label here replaces whatever the pill inside
        // says — the same reason `VisibilityMenu` carries one.
        .accessibilityLabel(
            ComposeMetaRow.photosAccessibilityLabel(count: count, isImporting: isImporting)
        )
    }
}

/// The photos pill's label — extracted for the same reason the other two are: so its fit is
/// measured rather than eyeballed.
struct PhotosPill: View {
    let count: Int
    var isImporting: Bool = false
    var spelling: ComposeMetaRow.Spelling = .short

    var title: String? {
        spelling == .glyph ? nil : ComposeMetaRow.photosTitle(count: count)
    }

    var body: some View {
        MetaPill(
            symbol: "photo.on.rectangle.angled",
            title: title,
            isSet: count > 0,
            isBusy: isImporting
        )
    }
}

/// One pill: a glyph, and a word beside it when the row has room for one.
///
/// Every control in the meta row is this shape, which is what makes the row read as a row rather
/// than as three unrelated controls — and what makes "it fits" a measurement of one thing.
///
/// `isBusy` draws the spinner ON the glyph rather than beside it. A spinner that arrives next to
/// something is a spinner that moves it, and the whole point of this row is that nothing moves.
struct MetaPill: View {
    let symbol: String
    var title: String?
    /// Whether this pill stands for a choice somebody made, rather than the default. It is the
    /// only thing that still says "there is a date on this memo" once the row is down to glyphs.
    var isSet: Bool = false
    var isBusy: Bool = false

    var body: some View {
        Group {
            if let title {
                Label {
                    Text(title)
                } icon: {
                    glyph
                }
                .labelStyle(.titleAndIcon)
            } else {
                glyph
            }
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, DesignTokens.Space.regular)
        .padding(.vertical, DesignTokens.Space.snug)
        .background(DesignTokens.accent.opacity(isSet ? 0.3 : 0.14), in: .capsule)
        .foregroundStyle(DesignTokens.accent)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .opacity(isBusy ? 0 : 1)
            .overlay {
                if isBusy {
                    ProgressView().controlSize(.mini)
                }
            }
    }
}
