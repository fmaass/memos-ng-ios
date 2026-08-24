import Foundation
import MemosOutbox
import MemosShareKit
import SwiftUI

/// The whole share sheet: what is being shared, a note, who will see it, and Post.
///
/// It PERSISTS and nothing more. The app owns the one background upload session — two processes
/// cannot share it — so this writes the capture into the queue in the app group and returns; the
/// bytes move on the app's next launch or background refresh.
struct ShareRootView: View {
    let providers: [NSItemProvider]
    let finish: () -> Void
    let cancel: () -> Void

    @State private var items: [SharedItem] = []
    @State private var failed = 0
    @State private var note = ""
    @State private var visibility: ShareVisibility?
    /// Who the app last said is signed in. The extension has no session and no token of its own —
    /// see `OutboxAccountStore`.
    @State private var account: AccountBinding?
    @State private var isReading = true
    @State private var isPosting = false
    @State private var problem: String?
    /// Where the providers' files are copied to before the outbox takes its own copy. Held in
    /// state so it survives a redraw, and removed on the way out either way.
    @State private var staging = URL.temporaryDirectory
        .appending(path: "share-\(UUID().uuidString)")

    private var canPost: Bool {
        account != nil
            && ShareComposition.canPost(
                note: note, items: items, failed: failed, isBusy: isReading || isPosting
            )
    }

    var body: some View {
        NavigationStack {
            Form {
                if isReading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading what you shared…")
                    }
                } else if account == nil {
                    Text("Sign in to memos in the app first, then share again.")
                        .foregroundStyle(.secondary)
                }
                if let problem {
                    Text(problem).foregroundStyle(.orange)
                }
                if !items.isEmpty {
                    Section {
                        ForEach(Array(items.enumerated()), id: \.offset) { entry in
                            Label(
                                Self.title(for: entry.element),
                                systemImage: Self.symbol(for: entry.element)
                            )
                            .lineLimit(1)
                        }
                    } header: {
                        Text(ShareComposition.summary(items: items, failed: failed) ?? "Shared")
                    }
                }
                Section("Note") {
                    TextField("Say something about this", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("Visibility") {
                    Picker("Visibility", selection: $visibility) {
                        Text("Account default").tag(ShareVisibility?.none)
                        Text("Private").tag(ShareVisibility?.some(.private))
                        Text("Protected").tag(ShareVisibility?.some(.protected))
                        Text("Public").tag(ShareVisibility?.some(.public))
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Share to memos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        discardStaging()
                        cancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { Task { await post() } }
                        .disabled(!canPost)
                }
            }
        }
        .task { await read() }
    }

    private func read() async {
        account = OutboxAccountStore.live()?.current()
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let loaded = await SharedItemLoader.load(providers, into: staging)
        items = loaded.items
        failed = loaded.failed
        isReading = false
    }

    private func post() async {
        // No fallback container here, deliberately: the app is the only process that drains, so a
        // capture written anywhere but the app group is a capture nobody will ever send.
        guard let root = OutboxRepository.appGroupRoot() else {
            problem = "This device cannot reach the memos queue. Open the app and try again."
            return
        }
        isPosting = true
        defer { isPosting = false }
        do {
            let repository = try OutboxRepository(root: root)
            let outcome = try await ShareIngest.commit(
                items: items,
                note: note,
                visibility: visibility,
                binding: account,
                into: repository
            )
            switch outcome {
            case .enqueued:
                discardStaging()
                finish()
            case .notSignedIn:
                problem = "Sign in to memos in the app first, then share again."
            case .nothingToPost:
                problem = "There is nothing here to keep."
            }
        } catch {
            problem = "This share could not be saved on the device: \(error.localizedDescription)"
        }
    }

    /// The outbox has its own copy of everything it accepted, so the staged copies are rubbish the
    /// moment this sheet is done with them.
    private func discardStaging() {
        try? FileManager.default.removeItem(at: staging)
    }

    private static func title(for item: SharedItem) -> String {
        switch item {
        case .file(let file): return file.filename
        case .link(let url): return url.absoluteString
        case .text(let text): return text
        }
    }

    /// A symbol, not a thumbnail: decoding a 48-megapixel original to draw it 40 points wide is
    /// exactly the memory a share extension does not have.
    private static func symbol(for item: SharedItem) -> String {
        switch item {
        case .file(let file):
            if file.mime.hasPrefix("video/") { return "film" }
            if file.mime.hasPrefix("image/") { return "photo" }
            return "doc"
        case .link: return "link"
        case .text: return "text.quote"
        }
    }
}
