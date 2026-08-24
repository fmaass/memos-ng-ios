import MemosCore
import PhotosUI
import SwiftUI

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
public struct ComposeView: View {
    public enum Mode: Equatable {
        case create
        /// An edit opens on the memo as it stands, its display date included — the date row is a
        /// change to something that already has one, not a blank to fill in.
        case edit(uid: String, content: String, createdAt: Date)
    }

    let mode: Mode
    let submit: (ComposeSubmission) async -> Bool

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
    @State private var attachments: [PickedMedia] = []
    @State private var failedImports = 0
    /// Which pick the loading in flight belongs to. Choosing again before the first load has
    /// finished is ordinary behaviour, and the older, slower result must not overwrite the newer.
    @State private var importGeneration = 0
    @State private var isImporting = false
    @State private var isSaving = false
    @State private var detent: PresentationDetent = .medium
    @FocusState private var editorFocused: Bool

    public init(mode: Mode, submit: @escaping (ComposeSubmission) async -> Bool) {
        self.mode = mode
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
            imported: attachments.count,
            failed: failedImports,
            isBusy: isSaving || isImporting
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
                                attachments: attachments,
                                createdAt: date
                            )
                            if await submit(submission) { dismiss() }
                        }
                    }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                }
            }
            .task { editorFocused = true }
        }
        .tint(DesignTokens.accent)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
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
    /// An EDIT shows only the date row. Attachments are managed on the memo itself and visibility
    /// is its own deliberate action (see the type comment) — but a wrong date is a typo like any
    /// other, and fixing it is what this sheet is for.
    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            if !isEdit {
                if !attachments.isEmpty {
                    PickedThumbnailRow(attachments: attachments)
                }
                // At an accessibility text size the picker's label and the visibility pill cannot
                // share a line without one of them being squeezed, so they stop trying to.
                AttachControls(stacked: dynamicTypeSize.isAccessibilitySize) {
                    PhotosPicker(
                        selection: $picked,
                        selectionBehavior: .ordered,
                        matching: .any(of: [.images, .videos]),
                        preferredItemEncoding: .current
                    ) {
                        Label("Add photos", systemImage: "photo.on.rectangle.angled")
                            .font(.subheadline)
                    }
                    if isImporting {
                        ProgressView()
                    }
                } trailing: {
                    metaPills
                }
                if failedImports > 0,
                    let summary = ComposeAttachments.summary(
                        imported: attachments.count, failed: failedImports
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
            } else {
                // An edit manages neither attachments nor visibility, so the date is the whole
                // meta row on that path.
                MemoDateRow(date: $date, clearable: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.regular)
        .onChange(of: picked) { _, items in
            Task { await importPicked(items) }
        }
        .onChange(of: attachments.isEmpty) { _, isEmpty in
            // Photos are the reason to want the room; the sheet takes it rather than making
            // someone drag it open to see what they just attached.
            if !isEmpty { detent = .large }
        }
    }

    /// The two facts a capture carries besides its words: WHEN it happened and who can see it.
    ///
    /// Side by side, as two pills of the same idiom. The date used to sit on a line of its own
    /// below the picker, styled quietly, and people looked straight past it — someone went hunting
    /// for a control that was on the screen the whole time. A control nobody finds is not a
    /// subtle control, it is a missing one.
    @ViewBuilder
    private var metaPills: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
                MemoDateRow(date: $date, clearable: true)
                VisibilityMenu(
                    selection: $visibility,
                    accountDefault: session?.defaultVisibility
                )
            }
        } else {
            HStack(spacing: DesignTokens.Space.snug) {
                MemoDateRow(date: $date, clearable: true)
                VisibilityMenu(
                    selection: $visibility,
                    accountDefault: session?.defaultVisibility
                )
            }
        }
    }

    /// The picker hands back its own temporary export; each one is copied here, in order, and the
    /// copies are what the outbox takes over.
    private func importPicked(_ items: [PhotosPickerItem]) async {
        importGeneration += 1
        let generation = importGeneration
        isImporting = true
        var imported: [PickedMedia] = []
        var failed = 0
        for item in items {
            guard let media = try? await item.loadTransferable(type: PickedMedia.self) else {
                // Counted, not skipped: see ComposeAttachments.
                failed += 1
                continue
            }
            imported.append(media)
        }
        // A newer pick started while this one was loading; that one owns the outcome.
        guard generation == importGeneration else { return }
        attachments = imported
        failedImports = failed
        isImporting = false
    }

    private func clearPicked() {
        importGeneration += 1
        picked = []
        attachments = []
        failedImports = 0
        isImporting = false
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
            VisibilityChoicePill(selection: selection, accountDefault: accountDefault)
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var title: String? {
        VisibilityChoice.title(
            selection: selection,
            accountDefault: accountDefault,
            compact: dynamicTypeSize.isAccessibilitySize
        )
    }
    var symbol: String {
        VisibilityChoice.symbol(selection: selection, accountDefault: accountDefault)
    }

    var body: some View {
        Group {
            if let title {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol)
                }
                .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: symbol)
            }
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, DesignTokens.Space.regular)
        .padding(.vertical, DesignTokens.Space.snug)
        .background(DesignTokens.accent.opacity(0.14), in: .capsule)
        .foregroundStyle(DesignTokens.accent)
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

/// The compose sheet's controls: side by side while they fit, stacked when the text is large
/// enough that they would otherwise fight over the width.
struct AttachControls<Leading: View, Trailing: View>: View {
    let stacked: Bool
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
                HStack(spacing: DesignTokens.Space.regular) { leading }
                trailing
            }
        } else {
            HStack(spacing: DesignTokens.Space.regular) {
                leading
                Spacer(minLength: DesignTokens.Space.snug)
                trailing
            }
        }
    }
}

/// When the memo happened, as one pill that opens a picker.
///
/// A capture is dated the moment it is written, and that is right almost every time — so the row
/// starts collapsed, saying "Now", and costs nothing to ignore. Tapping it opens the platform's
/// own date picker; changing anything there is what actually chooses a date, so opening the picker
/// out of curiosity does not silently backdate a memo. The ✕ puts it back to "Now".
///
/// There is no upper bound on what can be chosen. The web app's own picker sets none and the
/// server stores what it is given, and a client that quietly refused a date the other client
/// accepts would be the odd one out rather than the careful one.
struct MemoDateRow: View {
    @Binding var date: Date?
    /// Whether "no date of its own" is still available. It is the default for a new capture; a
    /// memo being edited already has a date, and there is nothing to clear it back to.
    var clearable: Bool = true

    @State private var isPicking = false
    /// What the picker opens on when nothing has been chosen. Captured when the picker opens
    /// rather than read inside `body`, which would move it on every redraw.
    @State private var seed = Date()

    /// The picker edits this rather than `date` directly, so that "no date chosen" survives merely
    /// looking at the picker: the memo takes a date when the picker's value MOVES.
    private var chosen: Binding<Date> {
        Binding(get: { self.date ?? self.seed }, set: { self.date = $0 })
    }

    var body: some View {
        HStack(spacing: DesignTokens.Space.snug) {
            Button {
                seed = date ?? Date()
                isPicking = true
            } label: {
                MemoDatePill(date: date)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Memo date")
            .accessibilityValue(MemoDateChoice.title(for: date))
            if clearable, date != nil {
                Button {
                    date = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use the time of writing")
            }
        }
        .popover(isPresented: $isPicking) {
            DatePicker(
                "Memo date",
                selection: chosen,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(DesignTokens.Space.regular)
            // A popover rather than the sheet iOS would otherwise substitute on a phone: the
            // compose sheet is already a sheet, and a second one over it hides the memo being
            // dated behind the picker that dates it.
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// The date row's label — extracted so its fit at the largest text size is measured directly
/// (`DynamicTypeFittingTests`), the same way the visibility pill is.
struct MemoDatePill: View {
    let date: Date?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var title: String {
        MemoDateChoice.title(for: date, compact: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "calendar")
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, DesignTokens.Space.regular)
        .padding(.vertical, DesignTokens.Space.snug)
        .background(DesignTokens.accent.opacity(0.14), in: .capsule)
        .foregroundStyle(DesignTokens.accent)
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
}
