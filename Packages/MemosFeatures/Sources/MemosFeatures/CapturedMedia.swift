import Foundation

/// Why a capture could not be staged.
///
/// Both cases refuse rather than repair. A still whose container nobody recognises is not written
/// under a guessed extension and a recording that is not on disk is not stood in for: the whole
/// point of this path is that the bytes reaching the outbox are the camera's own, and a stage that
/// invents something to hand on has already broken that.
nonisolated public enum CaptureStagingError: Error, Equatable {
    /// The photo output handed over bytes that are neither HEIF nor JPEG.
    case unrecognisedStill
    /// The movie output reported a recording at a path with nothing at it.
    case recordingMissing(String)
}

/// What a still the camera produced actually IS, read from its own first bytes.
///
/// The container is sniffed rather than assumed, because the extension and the MIME type the
/// server is told have to be true of the file and not of what was asked for. `AVCapturePhotoOutput`
/// answers with whatever the device could encode: a phone asked for HEIF that has no HEVC encoder
/// available answers in JPEG, and a capture stored as `.heic` because that is what the settings
/// said is a file whose name lies about it.
nonisolated public enum CapturedStill {
    public enum Format: String, Sendable, Equatable, CaseIterable {
        case heif
        case jpeg

        public var pathExtension: String {
            switch self {
            case .heif: "heic"
            case .jpeg: "jpg"
            }
        }

        public var mime: String {
            switch self {
            case .heif: "image/heic"
            case .jpeg: "image/jpeg"
            }
        }
    }

    /// The ISO base-media brands a HEIF still can arrive under. `heic`/`heix` are the ones an
    /// iPhone writes; the rest are the sequence and generic-image brands of the same family, and a
    /// file carrying one of them is still an untouched HEIF as far as this app is concerned —
    /// it is forwarded, never re-encoded, and the server does the deriving.
    static let heifBrands: Set<String> = [
        "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1",
    ]

    /// The format these bytes are in, or nil when they are in neither.
    ///
    /// Deliberately a look at the BYTES. Nothing here decodes, re-encodes or normalises anything:
    /// it reads the first twelve bytes and answers what they say.
    public static func format(of data: Data) -> Format? {
        let head = Array(data.prefix(12))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return .jpeg }
        guard head.count == 12 else { return nil }
        guard String(decoding: head[4..<8], as: UTF8.self) == "ftyp" else { return nil }
        let brand = String(decoding: head[8..<12], as: UTF8.self)
        return heifBrands.contains(brand) ? .heif : nil
    }
}

/// The name a capture carries to the server.
///
/// A file picked from the library arrives with the name the library gave it; one made here has
/// none, so it is given one that says when it was taken. It is a LABEL and never a path: the
/// outbox stores every file under an id of its own (`OutboxRepository.copy`), exactly as it does
/// for a name that came in from outside.
nonisolated public enum CaptureName {
    /// `IMG_20260828-141530.heic`, `VID_20260828-141530.mov`.
    public static func stamped(
        _ prefix: String,
        at date: Date,
        extension suffix: String,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        // POSIX and an explicit pattern: a name is not a place to let a locale decide anything.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)_\(formatter.string(from: date)).\(suffix)"
    }
}

/// The camera's boundary into the outbox: the two ways a capture becomes a `PickedMedia`.
///
/// It is `PickedMedia` and not a type of its own because that is the whole design. The compose
/// sheet already carries `[PickedMedia]`, `ComposeSubmission` already hands them to
/// `Outbox.enqueue` as `StagedSource`s, and the share extension reaches the same `enqueue` from
/// the other side — so a capture made here travels the identical queue, the identical manifest and
/// the identical chunked upload as a photo picked from the library. There is no second lane to
/// keep in step, which is the only way two lanes ever stay in step.
///
/// Neither of these encodes anything. The still is the photo output's own
/// `fileDataRepresentation()` written to disk unchanged; the recording is the movie output's own
/// file MOVED. The original is the archive master (ADR-0008), and the moment this layer re-wraps a
/// frame it stops being the original.
extension PickedMedia {
    /// A still, staged from the bytes the photo output represented it as.
    ///
    /// The bytes are written through untouched and the container decides both the extension and the
    /// MIME type. `data.write` is the only operation applied to them; there is no image object
    /// anywhere on this path, which is what makes "no re-encode" a property of the code rather than
    /// an intention stated in a comment.
    nonisolated public static func captured(
        photo data: Data,
        at date: Date = Date(),
        into directory: URL = .temporaryDirectory,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> PickedMedia {
        guard let format = CapturedStill.format(of: data) else {
            throw CaptureStagingError.unrecognisedStill
        }
        let id = UUID()
        let destination = directory.appending(path: "\(id.uuidString).\(format.pathExtension)")
        try? fileManager.removeItem(at: destination)
        try data.write(to: destination, options: .atomic)
        return PickedMedia(
            id: id,
            url: destination,
            filename: CaptureName.stamped(
                "IMG", at: date, extension: format.pathExtension, timeZone: timeZone
            ),
            mime: format.mime,
            lastModified: date
        )
    }

    /// A recording, staged by MOVING the file the movie output wrote.
    ///
    /// A move rather than a copy for two reasons, and neither is speed. A copy would leave the
    /// recording in two places, and the one nobody staged is the one nothing ever deletes — a
    /// household's worth of duplicated video in the temporary directory. And a move is the only
    /// operation that cannot rewrite: whatever else a later hand might be tempted to do to these
    /// bytes on the way past, `moveItem` has nowhere to do it.
    ///
    /// The recorder is given a scratch path because the staged name is derived from a fresh id, the
    /// same discipline `imported` follows — a name decides where a file lands only if you let it.
    nonisolated public static func captured(
        movie source: URL,
        at date: Date = Date(),
        into directory: URL = .temporaryDirectory,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> PickedMedia {
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw CaptureStagingError.recordingMissing(source.lastPathComponent)
        }
        let id = UUID()
        let suffix = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let destination = directory.appending(path: "\(id.uuidString).\(suffix)")
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: source, to: destination)
        return PickedMedia(
            id: id,
            url: destination,
            filename: CaptureName.stamped("VID", at: date, extension: suffix, timeZone: timeZone),
            mime: mimeType(forExtension: suffix),
            lastModified: date
        )
    }
}
