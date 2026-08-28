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

    public init() {}

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
        lastError = nil
        defer { isSaving = false }
        do {
            saved = FetchedFile(url: try await download(attachment))
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

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: Self.activityItems(for: url), applicationActivities: nil
        )
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
                ShareSheet(url: original.url)
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
