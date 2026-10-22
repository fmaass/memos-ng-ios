import Foundation
import MemosCore
import SwiftUI
import UIKit

/// A file that has been fetched and is waiting to be handed somewhere.
///
/// It carries the URL rather than the bytes: the share sheet takes a file, and a file is what
/// makes "Save Image" and "Save to Files" appear at all — a `Data` of unknown type gets neither.
/// The URL is a LOCAL one, always — `file:` under this app's temporary directory. A remote URL
/// here would be the MEMNG-207 defect back again, since this value is exactly what the share
/// sheet is presented on.
public struct FetchedFile: Identifiable, Equatable, Sendable {
    public let url: URL

    public var id: String { url.absoluteString }
}

/// The files a flow fetched and has not thrown away yet, and the rule about when they go.
///
/// It is a separate object because the LAST release has to happen when the flow's scope ends, and
/// a `@MainActor` class cannot do that itself: its `deinit` is not on the main actor and may not
/// touch its own isolated state. This object is nonisolated, its lock is what makes that honest,
/// and its deallocation IS its owner's — so `deinit` here is exactly the moment the screen that
/// fetched the file went away.
///
/// Neither of its release points is anything the share sheet says. That is the whole design, and
/// the reason is what Apple documents about the other end. `UIActivityViewController`'s completion
/// handler is "the completion handler to execute after the activity view controller is dismissed"
/// and runs "when the user-selected service finishes operating on the data, OR when the user
/// dismisses the view controller" — it is a dismissal signal, not a statement that anybody has
/// finished reading. What the receiver was actually given is an `NSItemProvider`, and
/// `loadInPlaceFileRepresentation` is documented to open the sender's file IN PLACE when it can
/// ("you must access the returned URL using an `NSFileCoordinator` object"), asynchronously, in the
/// receiving process. There is no callback anywhere that tells the SENDER the last reader is done.
/// So a delete at dismissal races a reader by construction, and this releases by SCOPE instead:
/// the file lives as long as the flow that fetched it, or until that same flow fetches its
/// replacement — both of which are strictly later than the sheet, and both of which need a
/// deliberate further act from the person using the app.
///
/// The removal itself is then taken under coordinated write access, which is the one documented
/// way for a writer to exclude a reader it cannot see: the receiver's read is coordinated because
/// Apple requires it to be, so a `.forDeleting` write waits for that read rather than landing in
/// the middle of it.
/// `nonisolated` because this layer's default isolation is the main actor and a `deinit` is not:
/// its release has to be callable from wherever the last reference happened to go.
nonisolated final class FetchedFileHold: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL] = []
    private let remove: @Sendable ([URL]) -> Void

    init(remove: @escaping @Sendable ([URL]) -> Void = FetchedFileHold.removeLater) {
        self.remove = remove
    }

    /// Takes charge of a file a fetch produced. Called BEFORE the file is offered anywhere, so
    /// nothing is ever offered that this is not keeping alive.
    func hold(_ file: URL) {
        lock.lock()
        files.append(file)
        lock.unlock()
    }

    /// Everything held goes, and the hold is empty afterwards.
    ///
    /// The claim is taken synchronously under the lock and the list is emptied in the same
    /// critical section, so two releases arriving at once — a fetch superseding the last file
    /// while the flow is being torn down — remove each path exactly once between them. A path
    /// removed twice is not merely wasted work: `fetch` gives every download an enclosure of its
    /// own, and a second removal is a removal of whatever is at that path by then.
    func release() {
        lock.lock()
        let going = files
        files = []
        lock.unlock()
        guard !going.isEmpty else { return }
        remove(going)
    }

    deinit { release() }

    /// How a file that has been handed to another process is thrown away.
    ///
    /// Off this thread because a coordinated write waits for readers, and the thread it would wait
    /// on here is the one the screen is drawn on.
    static let removeLater: @Sendable ([URL]) -> Void = { files in
        Task.detached(priority: .utility) {
            for file in files { FetchedFileHold.removeCoordinated(file) }
        }
    }

    /// Removes one fetched file the way a file somebody else may still be reading has to be
    /// removed: under a `.forDeleting` coordinated write, which is what a receiver's own
    /// coordinated read excludes.
    ///
    /// What actually goes is `OriginalMedia.discard`'s business — the file AND the enclosure the
    /// fetch made for it — so the rule about what a download leaves behind stays in the one place
    /// that states it.
    static func removeCoordinated(_ file: URL) {
        // When coordination itself fails the accessor never runs and nothing is removed — and
        // that is the correct outcome, not a gap to patch: a coordinator that declined proves
        // nothing about who may still be reading, so removing anyway would bypass the very
        // exclusion this function exists to provide. The file stays for the system's own reaping
        // of the temp directory, the backstop that bounded this leak before it was closed.
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: nil) {
            OriginalMedia.discard($0)
        }
    }
}

/// Getting a photo or a clip onto the phone, and then out of the app.
///
/// It is a two-step act and both steps have to be visible, which is why this is a model rather
/// than a closure in a menu. The download is not instant — an original is the archive master, and
/// over a household connection a video is a real wait — so something has to say it is happening,
/// something has to say when it will not, and the share sheet may only appear once there is a file
/// to put in it.
///
/// The download itself is passed IN, exactly as `MemoEditFlow`'s save is, and for the same reason:
/// the fetch needs the session's credential, this layer has no session, and a model that reached
/// for one would be untestable for precisely that reason.
@MainActor
@Observable
public final class MediaSaveFlow {
    /// A download is running. It is also the guard: a second tap must not fetch the same file
    /// twice, which on a video is a second few hundred megabytes for nothing.
    public private(set) var isSaving = false
    /// The file, once it is here. The share sheet is presented on this and on nothing else, so a
    /// failed download can never raise an empty one — and so the only thing that sheet can ever be
    /// handed is a file this flow fetched.
    public private(set) var saved: FetchedFile?
    /// Why the last attempt did not produce a file, or nil.
    public private(set) var lastError: String?

    /// The file this flow fetched, for exactly as long as this flow is around to offer it. What it
    /// releases, and when, is `FetchedFileHold` — and the "when" is the whole of MEMNG-210.
    private let held: FetchedFileHold

    public init() { held = FetchedFileHold() }

    /// The same flow with the removal handed in, so a test can watch what is thrown away without
    /// a filesystem in the middle of the assertion. The default is the real one.
    init(remove: @escaping @Sendable ([URL]) -> Void) { held = FetchedFileHold(remove: remove) }

    /// Fetches the file and, if it arrives, offers it.
    ///
    /// - Returns: whether this call actually ran a download — false for the tap that arrived while
    ///   another was already in flight.
    @discardableResult
    public func save(
        _ attachment: MemoAttachment,
        download: @MainActor (MemoAttachment) async throws -> URL
    ) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        // A new fetch is where the last one stops being wanted, and it is the first of the two
        // points the file it produced is released at (`FetchedFileHold`). The offer goes first, so
        // nothing is left pointing at a path that is about to be removed.
        saved = nil
        lastError = nil
        held.release()
        defer { isSaving = false }
        do {
            let file = try await download(attachment)
            // Held BEFORE it is offered: this flow never offers a file it is not keeping alive.
            held.hold(file)
            saved = FetchedFile(url: file)
            return true
        } catch {
            // Nothing is offered: the sheet is bound to `saved`, so a failure cannot raise one
            // over a file that is not there.
            saved = nil
            lastError = Self.message(for: error)
            return true
        }
    }

    /// The share sheet has gone. The file stops being offered — without this the same sheet comes
    /// straight back, because the binding it is presented on still holds a value.
    ///
    /// It stops being OFFERED and it is not deleted, and that is deliberate (MEMNG-210). The sheet
    /// closing says nothing about whether the app it handed the file to has finished reading it:
    /// the handover is an `NSItemProvider`, the read happens in the other process, and there is no
    /// callback that tells this side it is over. So the file is released by scope instead — see
    /// `FetchedFileHold`.
    public func finish() {
        saved = nil
    }

    public func dismissError() {
        lastError = nil
    }

    /// What a failed download says. The error's own sentence when it has one, because those name
    /// the actual reason — a dead credential, a file with no original, a server that refused.
    static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? Self.fallbackMessage
    }

    static let fallbackMessage = "This file could not be downloaded. Nothing was saved."
}

/// The system share sheet over one file.
///
/// A `UIActivityViewController` rather than SwiftUI's built-in share-link control, and the
/// difference is the point: that control is a BUTTON, and the file it would share does not exist
/// until somebody has waited for it. This is presented after the download, on the file that
/// arrived.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    /// What the activity controller is handed, as a value something other than UIKit can read.
    ///
    /// A function rather than a literal inside `makeUIViewController` because the contents of that
    /// array are the whole of MEMNG-207: the one thing this app may hand a share sheet is the
    /// FILE. A `Context` cannot be built outside SwiftUI, so with the array written inline there
    /// was nothing any test could look at — and what was silently in it, on the other share row,
    /// was a signed URL into the household server.
    static func activityItems(for file: URL) -> [URL] { [file] }

    /// Called once the share has COMPLETED; see `controller(items:onComplete:)`.
    var onComplete: @MainActor @Sendable () -> Void = {}

    /// The activity controller this sheet shows, with the one thing it must do on the way out.
    ///
    /// A completed share dismisses the activity controller, but not the SwiftUI sheet hosting it —
    /// nothing clears the sheet's binding, so the empty sheet stayed up after a share to Telegram
    /// (owner, 2.4.0 58/59). `completed` clears it; a cancel is the sheet's own dismissal already.
    /// Clearing the binding only stops the offer — the file stays held (`FetchedFileHold`,
    /// MEMNG-210) and is never deleted here.
    static func controller(
        items: [URL], onComplete: @escaping @MainActor @Sendable () -> Void
    ) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            guard completed else { return }
            MainActor.assumeIsolated { onComplete() }
        }
        return controller
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        Self.controller(items: Self.activityItems(for: url), onComplete: onComplete)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension View {
    /// The three things a screen that fetches a file has to show: that a download is running, the
    /// sheet when the file arrives, and the reason when it does not.
    ///
    /// One modifier rather than three lines on each of the two screens that offer it — the tile
    /// menu and the full-screen viewer offer the same actions, and a second copy written into a
    /// second body is how one of them ends up silently missing the failure.
    func fetchingFile(_ flow: MediaSaveFlow) -> some View {
        self
            .overlay {
                if flow.isSaving {
                    ProgressView()
                        .controlSize(.large)
                        .padding(DesignTokens.Space.roomy)
                        .background(
                            .regularMaterial,
                            in: .rect(cornerRadius: DesignTokens.Radius.card)
                        )
                        .accessibilityLabel("Downloading the file")
                }
            }
            .sheet(
                item: Binding(get: { flow.saved }, set: { if $0 == nil { flow.finish() } })
            ) { original in
                ShareSheet(url: original.url, onComplete: { flow.finish() })
            }
            .alert(
                "Could not download",
                isPresented: Binding(
                    get: { flow.lastError != nil },
                    set: { if !$0 { flow.dismissError() } }
                )
            ) {
                Button("OK", role: .cancel) { flow.dismissError() }
            } message: {
                Text(flow.lastError ?? MediaSaveFlow.fallbackMessage)
            }
    }
}
