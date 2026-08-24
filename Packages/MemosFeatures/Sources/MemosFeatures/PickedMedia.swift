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

    public var stagedSource: StagedSource {
        StagedSource(url: url, filename: filename, mime: mime, lastModified: lastModified)
    }
}
