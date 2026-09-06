import Foundation
import MemosOutbox
import UniformTypeIdentifiers

/// A file the share sheet handed over, copied out of the provider byte for byte.
///
/// The copy is FILE-based on purpose, and doubly so here: a share extension is given a fraction of
/// the memory an app has, and a 700 MB video read into a `Data` ends the process before the memo
/// exists. Nothing in this type ever holds the bytes — `FileManager` moves them from the
/// provider's export to a copy this process owns, and the outbox copies that into its container.
public struct SharedFile: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// A copy in this process's own temporary directory, which the outbox then takes over.
    public var url: URL
    /// The name the file arrived with — sent to the server, never used as a path here.
    public var filename: String
    public var mime: String
    public var lastModified: Date?
    /// The zone this file was IMPORTED in, which is where a wall-clock capture time with no offset
    /// of its own is resolved.
    ///
    /// It is carried rather than read at Post because those are two different moments: the share
    /// sheet takes the files as it opens and can then stand for as long as somebody leaves it
    /// there, and a phone can be somewhere else by then. The date this memo takes must be the one
    /// the file meant where it was taken over, not the one the device is set to when Post is
    /// tapped.
    public var captureZone: TimeZone

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        mime: String,
        lastModified: Date? = nil,
        captureZone: TimeZone = .current
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mime = mime
        self.lastModified = lastModified
        self.captureZone = captureZone
    }

    /// The provider boundary, as one function so the copy can be checksummed in a test.
    ///
    /// A provider's exported file is only valid for the length of its completion handler, so this
    /// is called from inside it — and the copy lands under a name derived from a fresh id: a
    /// filename that arrives from outside decides where a file lands only if you let it.
    /// - Parameter zone: sampled HERE, at the import, and carried on the file — see `captureZone`.
    ///   `.current` and not `.autoupdatingCurrent`: a zone that re-resolves would move a date that
    ///   has already been decided.
    public static func imported(
        _ source: URL,
        into directory: URL,
        fileManager: FileManager = .default,
        zone: TimeZone = .current
    ) throws -> SharedFile {
        let id = UUID()
        let suffix = source.pathExtension
        let storedName = suffix.isEmpty ? id.uuidString : "\(id.uuidString).\(suffix)"
        let destination = directory.appending(path: storedName)
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: source, to: destination)
        let modified = try? destination.resourceValues(forKeys: [.contentModificationDateKey])
        return SharedFile(
            id: id,
            url: destination,
            filename: source.lastPathComponent,
            mime: mimeType(forExtension: suffix),
            lastModified: modified?.contentModificationDate,
            captureZone: zone
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

    /// What the upload takes over, carrying this import's own token — see `StagedSource.identity`.
    public var stagedSource: StagedSource {
        StagedSource(
            url: url, filename: filename, mime: mime, lastModified: lastModified, identity: id)
    }
}

/// One thing the system share sheet offered, in the only three shapes this app takes.
///
/// A link and a piece of text are kept apart rather than flattened into one string at the door:
/// a share from a browser arrives as both — the page's title and its address — and only the
/// memo's text knows what to do with the pair.
public enum SharedItem: Sendable, Equatable {
    case file(SharedFile)
    case text(String)
    case link(URL)

    public var file: SharedFile? {
        if case .file(let file) = self { return file }
        return nil
    }

    public var isFile: Bool { file != nil }
}
