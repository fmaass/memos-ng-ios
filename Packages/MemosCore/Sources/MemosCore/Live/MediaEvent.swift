import Foundation

/// Where an attachment is in the media pipeline.
///
/// The five values are the server's own enum, `AttachmentStatus` in memos-ng `app/models.py:31-36`,
/// and they arrive on the wire as its `.value` (`app/routers/assets.py:802`).
public enum MediaAttachmentStatus: String, Sendable, Equatable, CaseIterable {
    case uploading
    case pending
    case processing
    case ready
    case failed

    /// Whether the backend will move an attachment on from here by itself.
    ///
    /// The same classification the SPA makes in `frontend/src/lib/sseLifecycle.ts:9-16`, and it is
    /// there for the same reason: the stream is a POLL, so a snapshot taken before a job finished
    /// can be delivered after the terminal event, and a client that has seen `ready` must not be
    /// talked back out of it by a late `processing`.
    public var isTerminal: Bool {
        switch self {
        case .uploading, .pending, .processing:
            return false
        case .ready, .failed:
            return true
        }
    }
}

/// One attachment's progress, as the server reports it on `/api/events`.
///
/// The shape is the server's, not a convenience of this client's. Two payloads reach the wire:
///
/// - a change in a NON-ready attachment — `{uid, status, progress_pct}`, built by
///   `_user_snapshot` in memos-ng `app/routers/assets.py:802` and emitted at
///   `app/routers/assets.py:748`;
/// - a synthetic `ready`, emitted when a uid DROPS OUT of the non-ready snapshot
///   (`app/routers/assets.py:757-761`) — `{uid, status: "ready", progress_pct: 100}` merged with
///   the layout metadata `_ready_meta` reads back, `{width, height, blurhash}`
///   (`app/routers/assets.py:819`), each of which is null until the worker has written it.
///
/// `progress_pct` is the least-advanced unfinished job of that attachment, not a maximum across
/// its jobs (`app/routers/assets.py:771`) — so a video's fast lane finishing at 100 does not
/// report the slow transcode as done.
///
/// Every line number in this file is as of memos-ng a1d493c.
public struct MediaEvent: Sendable, Equatable {
    public let uid: String
    public let status: MediaAttachmentStatus
    /// Absent is not zero: an event without a percentage leaves the last known one in place rather
    /// than resetting a tile to the start (the SPA makes the same distinction in
    /// `frontend/src/composables/useMediaEvents.ts`, `patchAttachment`).
    public let progressPercent: Int?
    public let width: Int?
    public let height: Int?
    public let blurhash: String?

    public init(
        uid: String,
        status: MediaAttachmentStatus,
        progressPercent: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        blurhash: String? = nil
    ) {
        self.uid = uid
        self.status = status
        self.progressPercent = progressPercent
        self.width = width
        self.height = height
        self.blurhash = blurhash
    }

    /// The layout this event establishes, and only when the server sent BOTH halves of it.
    ///
    /// Deliberately a pair rather than two properties a caller reads one at a time: one dimension
    /// beside the other's stale value describes an aspect ratio neither source has, and that ratio
    /// is exactly what a tile is laid out from. Same rule as the SPA's `metadataPatch`.
    public var dimensions: (width: Int, height: Int)? {
        guard let width, let height else { return nil }
        return (width, height)
    }
}

/// Why an event could not become a `MediaEvent`. Every case is a SKIP, never a stream failure:
/// a channel that died on one unrecognised frame would be a channel a server-side addition breaks.
public enum MediaEventDecodingError: Error, Equatable {
    /// The stream named an event type this client does not consume.
    case unsupportedEventType(String)
    /// A status the server has but this client does not know yet.
    case unknownStatus(String)
    /// The payload was not the JSON object this channel carries.
    case malformed(String)
}

extension MediaEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case uid
        case status
        case progressPercent = "progress_pct"
        case width
        case height
        case blurhash
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        let rawStatus = try container.decode(String.self, forKey: .status)
        guard let status = MediaAttachmentStatus(rawValue: rawStatus) else {
            throw MediaEventDecodingError.unknownStatus(rawStatus)
        }
        self.status = status
        progressPercent = try Self.integer(container, .progressPercent)
        width = try Self.integer(container, .width)
        height = try Self.integer(container, .height)
        blurhash = try container.decodeIfPresent(String.self, forKey: .blurhash)
    }

    /// Reads a number that is an `Integer` column today (`app/models.py:336` and `:367`) without
    /// making the whole event unreadable if it ever arrives as a fraction. Skipping an event over
    /// its percentage would lose the STATUS it carries, which is the part that matters.
    private static func integer(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        guard let value = try container.decodeIfPresent(Double.self, forKey: key) else {
            return nil
        }
        guard value.isFinite, let rounded = Int(exactly: value.rounded()) else { return nil }
        return rounded
    }

    /// Turns one dispatched frame into an event, or says why it will be skipped.
    ///
    /// The type check is the forward-compatible half: today every frame this server sends is the
    /// spec's default `message` (`app/routers/assets.py:721-722` writes a bare `data:` line), so a
    /// frame that names anything else is something added since, addressed to a consumer that is
    /// not this one. Adding a name here is the one-line change when that day comes.
    public static func decode(_ frame: ServerSentEvent) throws -> MediaEvent {
        guard frame.type == ServerSentEvent.defaultType else {
            throw MediaEventDecodingError.unsupportedEventType(frame.type)
        }
        do {
            return try JSONDecoder().decode(MediaEvent.self, from: Data(frame.data.utf8))
        } catch let error as MediaEventDecodingError {
            throw error
        } catch {
            throw MediaEventDecodingError.malformed(String(describing: error))
        }
    }
}
