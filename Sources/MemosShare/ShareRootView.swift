import Foundation
import MemosOutbox
import MemosShareKit
import SwiftUI

/// The whole share sheet: what is being shared, a note, who will see it, and Post.
///
/// It PERSISTS first: the capture is written into the queue in the app group. When the app has
/// left a capture grant beside the licence that matches the issue the capture was enqueued under,
/// the extension then opens the uploads itself under the capture's own background session
/// (`ShareTransfer`); without one it stops there, and the bytes move on the app's next launch or
/// background refresh.
struct ShareRootView: View {
    let providers: [NSItemProvider]
    let finish: () -> Void
    let cancel: () -> Void

    @State private var items: [SharedItem] = []
    @State private var failed = 0
    @State private var note = ""
    @State private var visibility: ShareVisibility?
    /// Who the app last said a share goes to — the member at home, or a guest's trip pass — and
    /// which queue that is. The extension has no session and no token of its own: both are licence
    /// bindings the app published (see `OutboxAccountStore`, `ShareRoute`).
    @State private var route: ShareRoute?
    @State private var isReading = true
    @State private var isPosting = false
    @State private var problem: String?
    /// Where the bytes will go, said before Post: set when no capture grant would be handed over.
    @State private var uploadNotice: String?
    /// Where the providers' files are copied to before the outbox takes its own copy. Held in
    /// state so it survives a redraw, and removed on the way out either way.
    @State private var staging = URL.temporaryDirectory
        .appending(path: "share-\(UUID().uuidString)")

    private var canPost: Bool {
        guard let route else { return false }
        return ShareComposition.canPost(
            for: route.kind, note: note, items: items, failed: failed,
            isBusy: isReading || isPosting
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
                } else if route == nil {
                    Text(Self.signInFirst).foregroundStyle(.secondary)
                } else if let uploadNotice {
                    Text(uploadNotice).foregroundStyle(.secondary)
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
                // A guest upload has no visibility: the trip decides who sees it. The licence
                // carries no trip label, so the line names none rather than guessing one.
                if route?.kind == .guest {
                    Section("Trip") {
                        Text(Self.addingToTrip).foregroundStyle(.secondary)
                        // Post stays off for words alone; the sheet says why rather than refusing
                        // in silence.
                        if !isReading, !items.contains(where: \.isFile) {
                            Text(Self.tripTakesFiles).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Section("Visibility") {
                        Picker("Visibility", selection: $visibility) {
                            Text("Account default").tag(ShareVisibility?.none)
                            Text(ShareVisibility.private.label).tag(ShareVisibility?.some(.private))
                            Text(ShareVisibility.protected.label)
                                .tag(ShareVisibility?.some(.protected))
                            Text(ShareVisibility.public.label).tag(ShareVisibility?.some(.public))
                        }
                        .pickerStyle(.segmented)
                    }
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
        let opened = ShareRoute.live()
        route = opened
        // The capture grant is the MEMBER's alone, so is what this says about it: a guest share
        // has no grant path at all, and the trip's own sentence covers it.
        uploadNotice =
            opened?.kind == .member
            ? ShareUploadPlan.notice(licence: opened?.licence, grants: CaptureGrantStore.live())
            : nil
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let loaded = await SharedItemLoader.load(providers, into: staging)
        items = loaded.items
        failed = loaded.failed
        isReading = false
    }

    private func post() async {
        guard let opened = route else {
            problem = Self.signInFirst
            return
        }
        let kind = opened.kind
        // No fallback container here, deliberately: the app is the only process that drains, so a
        // capture written anywhere but the app group is a capture nobody will ever send.
        guard let root = ShareRoute.appGroupRoot(for: kind) else {
            problem = "This device cannot reach the memos queue. Open the app and try again."
            return
        }
        isPosting = true
        defer { isPosting = false }
        // Read AT THE MOMENT OF USE, never trusted from when the sheet opened: this sheet can sit
        // on screen for hours, and a sign-out or an account switch in the app underneath it must
        // not be posted through. The value read here is the one the job is stamped with, and the
        // one the sheet was opened with is what it is checked against. The queue is the one the
        // sheet was opened for: a pass that ended, or one that began, under the sheet reads as no
        // licence for it, so a trip capture is never posted home nor a home capture to the trip.
        do {
            let repository = try OutboxRepository(root: root)
            let outcome = try await ShareIngest.commit(
                items: items,
                note: note,
                visibility: kind == .guest ? nil : visibility,
                // Handed as a READ rather than as a value: the commit awaits the capture reads
                // before it writes anything, and what stamps the job has to be the licence as it
                // stands then.
                licence: { ShareRoute.liveLicence(for: kind) },
                expecting: opened.licence.binding,
                into: repository
            )
            switch outcome {
            case .enqueued(let job, let admitted):
                // The capture is queued. Member queue only from here: its session, licence and
                // capture grant are the member's, and a guest capture must never be sent under
                // them — the guest outbox in the app sends it. With a grant stamped with the
                // licence issue the capture was ADMITTED under — present and unexpired — the
                // extension also opens its upload sessions and hands the files to the capture's
                // own background session; every request presents the grant, never the session
                // token. Without one this starts nothing and the app sends it.
                if kind == .member {
                    let grants = CaptureGrantStore(root: root)
                    let credential = ShareUploadPlan.credential(
                        enqueuedUnder: admitted, grants: grants)
                    _ = await ShareTransfer.live(
                        jobID: job, credential: credential, root: root, repository: repository,
                        // Read from the files at every ask: a sign-out, an account change or a
                        // re-mint in the app ends this grant's standing, and the app is another
                        // process.
                        stillCurrent: { epoch in
                            grants.stillStands(
                                epoch: epoch, enqueuedUnder: admitted,
                                standing: OutboxAccountStore(root: root).currentLicence())
                        }
                    )
                }
                // MEMNG-538 spike (kill date 2026-11-03): returns at once unless the debug switch
                // is on. The capture above is already queued either way. Member queue only: the
                // spike measures the home lane, and the guest queue is not its subject.
                if kind == .member {
                    await UploadSpikeShare.live(jobID: job, root: root)
                }
                discardStaging()
                finish()
            case .notSignedIn, .accountChanged:
                let now = ShareRoute.live()
                route = now
                problem = Self.refusal(openedFor: kind, now: now)
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
    static let addingToTrip = "Adding to the trip"
    static let tripTakesFiles = "A trip takes photos and videos. Share one to add it."

    /// What to say when the licence the sheet was opened for no longer stands — read from what
    /// the files say now, so the sheet shows where a second Post would go.
    private static func refusal(openedFor kind: CredentialKind, now: ShareRoute?) -> String {
        guard let now else {
            return kind == .guest
                ? "The trip pass on this phone has ended. Nothing was added."
                : signInFirst
        }
        if now.kind != kind {
            return now.kind == .guest
                ? "This phone now shares to a trip. Check this and post again."
                : "The trip pass on this phone has ended. Check this and post again to memos."
        }
        return "The account signed in to memos changed. Check this and post again."
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
