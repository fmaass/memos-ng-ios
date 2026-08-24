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
                    Text(Self.signInFirst).foregroundStyle(.secondary)
                }
                // Outside the item list on purpose: when NOTHING could be copied there are no
                // items to hang this off, and a sheet that says nothing while refusing to post is
                // a dead end.
                if !isReading, let summary = ShareComposition.summary(items: items, failed: failed)
                {
                    Text(summary).foregroundStyle(failed > 0 ? .orange : .secondary)
                }
                if let problem {
                    Text(problem).foregroundStyle(.orange)
                }
                if !items.isEmpty {
                    Section("Shared") {
                        ForEach(Array(items.enumerated()), id: \.offset) { entry in
                            Label(
                                Self.title(for: entry.element),
                                systemImage: Self.symbol(for: entry.element)
                            )
                            .lineLimit(1)
                        }
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
        // Read AT THE MOMENT OF USE, never trusted from when the sheet opened: this sheet can sit
        // on screen for hours, and a sign-out or an account switch in the app underneath it must
        // not be posted through. The value read here is the one the job is stamped with, and the
        // one the sheet was opened with is what it is checked against.
        let licence = OutboxAccountStore.live()?.current()
        do {
            let repository = try OutboxRepository(root: root)
            let outcome = try await ShareIngest.commit(
                items: items,
                note: note,
                visibility: visibility,
                binding: licence,
                expecting: account,
                into: repository
            )
            switch outcome {
            case .enqueued:
                discardStaging()
                finish()
            case .notSignedIn:
                account = nil
                problem = Self.signInFirst
            case .accountChanged:
                account = licence
                problem = "The account signed in to memos changed. Check this and post again."
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

    static let signInFirst = "Sign in to memos in the app first, then share again."

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
