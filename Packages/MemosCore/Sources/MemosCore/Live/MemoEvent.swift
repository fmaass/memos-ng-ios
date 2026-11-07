import Foundation

/// What happened to one memo, as `/api/events` names it.
///
/// The three names are the server's (`MEMO_CREATED`, `MEMO_UPDATED`, `MEMO_DELETED` in memos-ng
/// `app/services/event_stream.py`, v2.14.0) and they are RELATIVE TO THE RECIPIENT. There is no
/// visibility event: a memo made private reaches the rest of the household as `deleted` and one
/// shared again as `created`, while its owner — who sees it either way — gets `updated`
/// (`memo_change_frames`). So "a memo I can no longer see" is a `deleted` to this client, and
/// nothing here has to work out who may see what.
public enum MemoEventKind: String, Sendable, Equatable, CaseIterable {
    case created
    case updated
    case deleted

    /// The SSE `event:` name the server sends this kind under.
    public var eventType: String { "memo.\(rawValue)" }
}

/// One memo frame: which memo, what happened to it, and whether a trip guest sent it in.
///
/// Ids only, by the server's design (`EventHub._publish_direct`): the row is the authority, so a
/// client that wants the memo reads it. `guest` is the one fact carried along, because it decides
/// whether the home timeline may show the memo at all (MEMNG-1164) and the memo model this client
/// keeps does not record it.
public struct MemoEvent: Sendable, Equatable {
    public let kind: MemoEventKind
    public let uid: String
    /// A trip-pass guest sent this memo in (`MemoOut.guest` is non-null).
    public let isGuest: Bool

    public init(kind: MemoEventKind, uid: String, isGuest: Bool = false) {
        self.kind = kind
        self.uid = uid
        self.isGuest = isGuest
    }

    private enum CodingKeys: String, CodingKey {
        case uid
        case guest
    }

    /// The frame's payload, `{uid, kind, guest}`. The KIND comes from the frame's `event:` name and
    /// not from the payload's `kind` field: the name is what the server routed on, and a payload is
    /// data, whose words are never read as the frame's type.
    static func decode(_ frame: ServerSentEvent, as kind: MemoEventKind) throws -> MemoEvent {
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(frame.data.utf8))
            return MemoEvent(kind: kind, uid: payload.uid, isGuest: payload.isGuest)
        } catch {
            throw MediaEventDecodingError.malformed(String(describing: error))
        }
    }

    private struct Payload: Decodable {
        let uid: String
        let isGuest: Bool

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uid = try container.decode(String.self, forKey: .uid)
            // Present and not null is a guest memo, whatever shape the object takes: the flag is
            // what decides, and a guest object grown by a field must not make the frame unreadable.
            if container.contains(.guest) {
                let absent = try container.decodeNil(forKey: .guest)
                isGuest = !absent
            } else {
                isGuest = false
            }
        }
    }
}

/// How far the server has received one upload, as `upload.progress` reports it.
///
/// Decoded and stamped, and consumed by nothing yet: the Transfers ledger is derived from what the
/// outbox planner itself confirmed, and it has no seam to take a second source keyed by the
/// server's upload uid.
public struct UploadProgressEvent: Sendable, Equatable {
    public let uploadUID: String
    public let bytesReceived: Int64
    public let declaredSize: Int64

    public init(uploadUID: String, bytesReceived: Int64, declaredSize: Int64) {
        self.uploadUID = uploadUID
        self.bytesReceived = bytesReceived
        self.declaredSize = declaredSize
    }
}

extension UploadProgressEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case uploadUID = "upload_uid"
        case bytesReceived = "bytes_received"
        case declaredSize = "declared_size"
    }

    /// The SSE `event:` name (`UPLOAD_PROGRESS_EVENT`, memos-ng `app/services/event_stream.py`).
    public static let eventType = "upload.progress"
}

/// Every frame `/api/events` carries that this client reads, by its `event:` name.
public enum LiveEvent: Sendable, Equatable {
    case media(MediaEvent)
    case memo(MemoEvent)
    case uploadProgress(UploadProgressEvent)

    /// Turns one dispatched frame into an event, or says why it will be skipped. Dispatch is on the
    /// frame's `event:` field alone, never on what its data says.
    public static func decode(_ frame: ServerSentEvent) throws -> LiveEvent {
        if frame.type == ServerSentEvent.defaultType {
            return .media(try MediaEvent.decode(frame))
        }
        if let kind = MemoEventKind.allCases.first(where: { $0.eventType == frame.type }) {
            return .memo(try MemoEvent.decode(frame, as: kind))
        }
        if frame.type == UploadProgressEvent.eventType {
            do {
                return .uploadProgress(
                    try JSONDecoder().decode(
                        UploadProgressEvent.self, from: Data(frame.data.utf8)))
            } catch {
                throw MediaEventDecodingError.malformed(String(describing: error))
            }
        }
        throw MediaEventDecodingError.unsupportedEventType(frame.type)
    }
}
