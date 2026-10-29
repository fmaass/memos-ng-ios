import CoreTransferable
import Foundation
import MemosOutbox
import UniformTypeIdentifiers

/// A file chosen in the photo library, copied out of it byte for byte.
///
/// The transfer is FILE-based on purpose: a `DataRepresentation` would load a 700 MB video into
/// memory, and asking the picker for an image would hand back a transcoded JPEG. The originals are
/// the archive master, so what the picker exports is copied unchanged — HEIC stays HEIC, HEVC
/// stays HEVC — and the server does the deriving.
///
/// `nonisolated`: `Transferable` is a `Sendable` protocol whose requirements are called off the
/// main actor by the picker, and this layer's declarations are main-actor by default.
nonisolated public struct PickedMedia: Transferable, Identifiable, Equatable {
    public var id: UUID
    /// A copy in the app's temporary directory that the outbox then copies into its own container.
    public var url: URL
    /// The name the file had in the library — sent to the server, never used as a path here.
    public var filename: String
    public var mime: String
    public var lastModified: Date?

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        mime: String,
        lastModified: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mime = mime
        self.lastModified = lastModified
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try PickedMedia.imported(received.file)
        }
        FileRepresentation(importedContentType: .movie) { received in
            try PickedMedia.imported(received.file)
        }
    }

    /// The picker boundary, as one function so the copy can be checksummed in a test.
    ///
    /// The exported file is only valid for the length of the import closure, so it is copied
    /// immediately — and it is copied under a name derived from a fresh id, because a filename
    /// that arrives from outside decides where a file lands only if you let it.
    public static func imported(
        _ source: URL,
        into directory: URL = .temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> PickedMedia {
        let id = UUID()
        let filename = source.lastPathComponent
        let suffix = source.pathExtension
        let storedName = suffix.isEmpty ? id.uuidString : "\(id.uuidString).\(suffix)"
        let destination = directory.appending(path: storedName)
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: source, to: destination)
        let modified = try? destination.resourceValues(forKeys: [.contentModificationDateKey])
        return PickedMedia(
            id: id,
            url: destination,
            filename: filename,
            mime: mimeType(forExtension: suffix),
            lastModified: modified?.contentModificationDate
        )
    }

    /// What the file actually is, from its own extension. `application/octet-stream` is the honest
    /// answer when the system does not know — the server sniffs the bytes anyway.
    public static func mimeType(forExtension suffix: String) -> String {
        guard !suffix.isEmpty,
            let type = UTType(filenameExtension: suffix.lowercased()),
            let mime = type.preferredMIMEType
        else { return "application/octet-stream" }
        return mime
    }

    /// What the upload takes over — carrying the COMPOSER's identity for this item.
    ///
    /// The identity is what makes a retried edit the same edit. A retry re-imports the picker's
    /// export under a fresh temporary name, so the url and the modification date both move; an edit
    /// key minted from those would change with them, and the server would answer a retry of a lost
    /// save as a NEW edit rather than as the replay it is (`TimelineStore.editKey(for:)`).
    public var stagedSource: StagedSource {
        StagedSource(
            url: url, filename: filename, mime: mime, lastModified: lastModified, identity: id)
    }
}

/// What the attach row has to say about what was picked.
///
/// A file the picker cannot export — an iCloud original that never came down, a corrupt asset — is
/// the one case that must not pass quietly: dropping it silently means someone posts a memo
/// believing a photo went with it and finds out weeks later that it did not.
nonisolated public enum ComposeAttachments {
    public static func summary(imported: Int, failed: Int) -> String? {
        if failed > 0 {
            let total = imported + failed
            return "\(failed) of \(total) could not be read. Remove them, or pick them again."
        }
        guard imported > 0 else { return nil }
        return imported == 1 ? "1 file attached" : "\(imported) files attached"
    }

    /// Whether there is a memo here at all: words, or a file. It is deliberately not the guard for
    /// anything else — see `postRefusal`, which refuses a post with something to read instead of
    /// with a grey button.
    public static func canPost(text: String, imported: Int, isBusy: Bool) -> Bool {
        guard !isBusy else { return false }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || imported > 0
    }

    /// Why this capture may not be posted YET, in one sentence naming the item that is holding it
    /// up — or nil when it may.
    ///
    /// Two things hold a post up, and both are about a single item rather than about a count. A
    /// file that could not be read must not be posted around: dropping it silently is the failure
    /// somebody discovers weeks later, and naming it is what makes "remove it or try again" an
    /// instruction about something identifiable. A file whose capture read has not come back yet
    /// must not be posted EITHER, whatever the date control says — the memo's date and the order of
    /// its pictures both depend on that answer, and a memo posted a second before it arrives is
    /// dated and ordered by an incomplete set for ever.
    ///
    /// A refusal, never a silent drop, and never a disabled button.
    ///
    /// `loadingGoesLater` is a capture whose loading files follow it into the queue (MEMNG-951):
    /// a file on its way is then not left out, it is sent behind the rest, so it holds nothing up.
    public static func postRefusal(
        items: [ComposeAttachment], loadingGoesLater: Bool = false
    ) -> String? {
        if let failed = items.first(where: \.isFailed) {
            return "\(failed.label) could not be read. Remove it, or try it again."
        }
        // A file still on its way is not attached yet. Posting now would send the memo without it
        // — the same silent loss a failed item causes, arrived at by waiting a second less.
        if !loadingGoesLater, let loading = items.first(where: \.isLoading) {
            return "\(loading.label) is still loading. Give it a moment, or remove it."
        }
        // A file still on its way has not been read either; when it follows later it is not
        // waited for here — the memo is dated by what is attached when Post is pressed.
        if let pending = items.first(where: {
            $0.capture.isPending && !(loadingGoesLater && $0.isLoading)
        }) {
            return "\(pending.label) is still being read. It decides the date, so give it a moment."
        }
        return nil
    }
}
