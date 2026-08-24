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
            VStack(spacing: 0) {
                TextEditor(text: $content)
                    .focused($editorFocused)
                    .font(.body)
                    .padding(8)
                if !isEdit {
                    attachRow
                    Picker("Visibility", selection: $visibility) {
                        Text("Server default").tag(MemoVisibility?.none)
                        Text("Private").tag(MemoVisibility?.some(.private))
                        Text("Protected").tag(MemoVisibility?.some(.protected))
                        Text("Public").tag(MemoVisibility?.some(.public))
                    }
                    .pickerStyle(.segmented)
                    .padding()
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
                }
            }
            .task { editorFocused = true }
        }
    }

    @ViewBuilder
    private var attachRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PhotosPicker(
                    selection: $picked,
                    selectionBehavior: .ordered,
                    matching: .any(of: [.images, .videos]),
                    preferredItemEncoding: .current
                ) {
                    Label("Add photos or videos", systemImage: "photo.on.rectangle.angled")
                }
                if isImporting {
                    ProgressView()
                }
            }
            if let summary = ComposeAttachments.summary(
                imported: attachments.count, failed: failedImports
            ) {
                HStack(spacing: 8) {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(failedImports > 0 ? .orange : .secondary)
                    if failedImports > 0 {
                        Button("Remove them") { clearPicked() }
                            .font(.footnote)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .onChange(of: picked) { _, items in
            Task { await importPicked(items) }
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
