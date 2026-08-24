import MemosCore
import PhotosUI
import SwiftUI

/// What the compose screen hands back when someone taps Post or Save.
public struct ComposeSubmission: Sendable, Equatable {
    public var content: String
    public var visibility: MemoVisibility?
    public var attachments: [PickedMedia]

    public init(content: String, visibility: MemoVisibility?, attachments: [PickedMedia] = []) {
        self.content = content
        self.visibility = visibility
        self.attachments = attachments
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
/// Photos and videos are attached from the LIBRARY, not captured in the app: something shot with
/// the system camera moments ago is already there, and an in-app stills camera would re-encode it.
public struct ComposeView: View {
    public enum Mode: Equatable {
        case create
        case edit(uid: String, content: String)
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
                if case .edit(_, let content) = mode { return content }
                return ""
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
                if !isEdit {
                    Divider()
                    attachRow
                }
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
                                attachments: attachments
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

    @ViewBuilder
    private var attachRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
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
                VisibilityMenu(
                    selection: $visibility,
                    accountDefault: session?.defaultVisibility
                )
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
                Label(
                    VisibilityChoice.title(selection: nil, accountDefault: accountDefault),
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
        .accessibilityLabel("Visibility")
    }
}

/// The label of the visibility menu — extracted so its fit at the largest text size can be
/// measured directly (`DynamicTypeFittingTests`) rather than eyeballed in a screenshot.
struct VisibilityChoicePill: View {
    let selection: MemoVisibility?
    var accountDefault: MemoVisibility?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var title: String {
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
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
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

/// What the visibility control says it will do.
///
/// "Default" on its own is the one answer that tells nobody anything: the whole question is who
/// will see this, and leaving the choice alone is only safe if you know what leaving it alone
/// means. So the account's own setting is named alongside it — and when the app does not know
/// that setting yet, it says "Default" rather than inventing one, because a wrong promise about
/// who can read a memo is worse than a vague one.
enum VisibilityChoice {
    /// `compact` drops the framing and keeps the answer. At an accessibility text size
    /// "Default (Protected)" wants 518pt of the 369 a compose sheet has, and a pill that refuses
    /// to truncate would simply run off the screen — so at those sizes it says "Protected", which
    /// is the part that was worth saying. The word it loses is the one the menu's checkmark
    /// already carries.
    static func title(
        selection: MemoVisibility?,
        accountDefault: MemoVisibility?,
        compact: Bool = false
    ) -> String {
        if let selection { return selection.label }
        guard let accountDefault else { return "Default" }
        return compact ? accountDefault.label : "Default (\(accountDefault.label))"
    }

    static func symbol(selection: MemoVisibility?, accountDefault: MemoVisibility?) -> String {
        selection?.symbolName ?? accountDefault?.symbolName ?? "person.crop.circle"
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
