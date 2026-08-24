import MemosCore
import SwiftUI

/// Writing a memo — new or edited, one screen.
///
/// Visibility offers "server default" as the unmarked choice on a NEW memo: the account already
/// has an answer for who sees things, and a compose screen that demands the decision every time
/// teaches people to stop reading it. An EDIT never touches visibility here — that is its own
/// deliberate action on the memo, not a side effect of fixing a typo.
public struct ComposeView: View {
    public enum Mode: Equatable {
        case create
        case edit(uid: String, content: String)
    }

    let mode: Mode
    let submit: (String, MemoVisibility?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var visibility: MemoVisibility?
    @State private var isSaving = false
    @FocusState private var editorFocused: Bool

    public init(mode: Mode, submit: @escaping (String, MemoVisibility?) async -> Bool) {
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

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $content)
                    .focused($editorFocused)
                    .font(.body)
                    .padding(8)
                if !isEdit {
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
                            if await submit(content, visibility) { dismiss() }
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .task { editorFocused = true }
        }
    }
}
