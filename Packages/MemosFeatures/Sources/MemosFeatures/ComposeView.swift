import MemosCore
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
/// Photos and videos are attached from the LIBRARY, not captured in the app: something shot with
/// the system camera moments ago is already there, and an in-app stills camera would re-encode it.
/// The destructive action an edit sheet offers, and the question it asks first.
///
/// It is handed IN rather than owned for the same reason the save is: the sheet has no store and no
/// client, and one that reached for them would be untestable for exactly that reason. The stage
/// belongs to `MemoEditFlow`; this carries only what the sheet needs to draw — whether the question
/// is up — and where to send the answer.
///
/// Mine-gating is inherent rather than re-checked here: the only thing that hands one of these over
/// is the memo's own screen, which opens the sheet solely for `MemoDetailPresentation.editMode`,
/// and that is nil for a memo that is not mine.
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

public struct ComposeView: View {
    public enum Mode: Equatable {
        case create
        /// An edit opens on the memo as it stands, its display date included — the date row is a
        /// change to something that already has one, not a blank to fill in.
        case edit(uid: String, content: String, createdAt: Date)
    }

    let mode: Mode
    let submit: (ComposeSubmission) async -> Bool
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
    @State private var imports = ComposeImports()
    @State private var isSaving = false
    @State private var detent: PresentationDetent = .medium
    /// What the sheet has up — its keyboard and its photo picker — as one value, so the order
    /// between them is a thing a test can hold. See `ComposeStage`.
    @State private var stage = ComposeStage()
    @FocusState private var editorFocused: Bool

    public init(
        mode: Mode,
        delete: ComposeDelete? = nil,
        submit: @escaping (ComposeSubmission) async -> Bool
    ) {
        self.mode = mode
        self.delete = delete
        self.submit = submit
        _content = State(
            initialValue: {
                if case .edit(_, let content, _) = mode { return content }
                return ""
            }())
        _date = State(
            initialValue: {
                if case .edit(_, _, let createdAt) = mode { return createdAt }
                return nil
            }())
    }

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// A memo with photos and no words is a memo. Only an empty capture — or one whose files did
    /// not all arrive — is refused.
    private var canSave: Bool {
        ComposeAttachments.canPost(
            text: content,
            imported: imports.attachments.count,
            failed: imports.failed,
            isBusy: isSaving || imports.isImporting
        )
    }

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
                    Button(isEdit ? "Save" : "Post") {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            let submission = ComposeSubmission(
                                content: content,
                                visibility: visibility,
                                attachments: imports.attachments,
                                createdAt: date
                            )
                            if await submit(submission) { dismiss() }
                        }
                    }
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
            // Stamped HERE, synchronously, as the selection lands — not inside the task, where
            // the number would order the loads' start times instead. See `ComposeImports`.
            let stamp = imports.selected()
            Task {
                await imports.load(items, stamp: stamp) {
                    try? await $0.loadTransferable(type: PickedMedia.self)
                }
            }
        }
        .onChange(of: imports.attachments.isEmpty) { _, isEmpty in
            // Photos are the reason to want the room; the sheet takes it rather than making
            // someone drag it open to see what they just attached.
            if !isEmpty { detent = .large }
        }
    }

    /// What has been picked, and what would not read. Shared by both modes: a file the picker
    /// cannot export is the one thing that must never pass quietly, whether it was picked for a
    /// new memo or added to one that already exists.
    @ViewBuilder
    private var attachedRow: some View {
        if !imports.attachments.isEmpty {
            PickedThumbnailRow(attachments: imports.attachments)
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
                Button("Remove them") { clearPicked() }
                    .font(.footnote)
            }
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
            // Not clearable: a memo being edited already has a date, and there is nothing to put
            // it back to — "now" would be a date this sheet invented.
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
            attachmentCount: imports.attachments.count,
            isImporting: imports.isImporting,
            date: $date,
            visibility: $visibility,
            accountDefault: session?.defaultVisibility
        )
    }

    /// What the picker's presentation binds to. Only dismissal comes back through it — the picker
    /// is opened by the pill and never by an assignment from outside, the same discipline
    /// `MemoEditFlow.sheet` is built on.
    private var pickingPhotos: Binding<Bool> {
        Binding(get: { stage.pickingPhotos }, set: { if !$0 { stage.photosPickerClosed() } })
    }

    /// Emptying the picker fences whatever it is still loading first: the selection this clears
    /// sets off its own import (of nothing), and a pick already on its way must not land between
    /// the two.
    private func clearPicked() {
        imports.clear()
        picked = []
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
            MemoDatePill(date: date, spelling: spelling)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Memo date")
        .accessibilityValue(MemoDateChoice.title(for: date))
        .popover(isPresented: $isPicking) {
            MemoDatePicker(date: $date, seed: seed, clearable: clearable) { isPicking = false }
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
    var onDone: () -> Void = {}

    /// The picker edits this rather than `date` directly, so that "no date chosen" survives merely
    /// looking at the picker: the memo takes a date when the picker's value MOVES.
    private var chosen: Binding<Date> {
        Binding(get: { self.date ?? self.seed }, set: { self.date = $0 })
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
                    Label("Now", systemImage: "clock")
                        .font(.subheadline)
                }
                .disabled(date == nil)
                .accessibilityLabel("Use the time of writing")
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
    var spelling: ComposeMetaRow.Spelling = .short

    var title: String? {
        spelling == .glyph ? nil : MemoDateChoice.pillTitle(for: date)
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
            MemoDateRow(date: $date, spelling: verbosity.date)
            VisibilityMenu(
                selection: $visibility,
                accountDefault: accountDefault,
                spelling: verbosity.visibility
            )
        }
    }
}

/// The photos pill, which OPENS the picker: it replaced an "Add photos or videos" button that sat
/// apart from the meta row and moved whenever anything in that row changed.
///
/// It ASKS rather than presents. A `PhotosPicker` control goes straight from the tap to the
/// presentation, leaving nowhere to put the keyboard down first — which is the moment the flicker
/// lived in (see `ComposeStage`). The presentation is a modifier on the sheet; this is the button
/// that reaches it, and it is a plain `Button` like the date pill beside it for that reason alone.
struct PhotosPickerPill: View {
    @Binding var stage: ComposeStage
    let count: Int
    var isImporting: Bool = false
    var spelling: ComposeMetaRow.Spelling = .short

    var body: some View {
        Button {
            stage.pickPhotos()
        } label: {
            PhotosPill(count: count, isImporting: isImporting, spelling: spelling)
        }
        .buttonStyle(.plain)
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
