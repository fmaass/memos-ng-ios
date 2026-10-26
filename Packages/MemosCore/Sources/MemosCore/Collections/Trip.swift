import Foundation
import MemosAPI

/// One trip as the server holds it (`CollectionOut`).
///
/// A trip is a household object: every signed-in member lists, opens and edits it, and the last
/// write wins. Its identity is the server's `uid`.
public struct Trip: Sendable, Equatable, Identifiable {
    /// What a collection is made of, fixed when it is created (memos-ng 2.6.0).
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// Its tag's and its span's pictures, less its exclusions.
        case trip
        /// No tag and no span: the pictures added to it one by one.
        case album
    }

    public var uid: String
    public var title: String
    public var kind: Kind
    /// The tag whose pictures are members, or nil for a trip made of its span alone.
    public var tag: String?
    /// The window in time whose pictures are members, both ends included; both or neither.
    public var spanStart: Date?
    public var spanEnd: Date?
    /// The zone the span was picked in, display only.
    public var tz: String?
    /// The cover as the library lists it, or nil when there is none or the caller may not see it.
    public var cover: LibraryRow?
    /// How many members the CALLER can see — two accounts may read different counts.
    public var memberCount: Int
    public var createdBy: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { uid }

    public init(
        uid: String,
        title: String,
        kind: Kind = .trip,
        tag: String? = nil,
        spanStart: Date? = nil,
        spanEnd: Date? = nil,
        tz: String? = nil,
        cover: LibraryRow? = nil,
        memberCount: Int = 0,
        createdBy: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.uid = uid
        self.title = title
        self.kind = kind
        self.tag = tag
        self.spanStart = spanStart
        self.spanEnd = spanEnd
        self.tz = tz
        self.cover = cover
        self.memberCount = memberCount
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The projection of the server's record. Its kind is the record's own: the contract always
    /// sends one, and a record without it fails to decode rather than being taken for a trip.
    init(_ generated: Components.Schemas.CollectionOut, baseURL: URL) {
        let kind: Kind =
            switch generated.kind {
            case .trip: .trip
            case .album: .album
            }
        self.init(
            uid: generated.uid,
            title: generated.title,
            kind: kind,
            tag: generated.tag,
            spanStart: generated.spanStart,
            spanEnd: generated.spanEnd,
            tz: generated.tz,
            cover: Self.row(generated.cover, baseURL: baseURL),
            memberCount: generated.memberCount,
            createdBy: generated.createdBy,
            createdAt: generated.createdAt,
            updatedAt: generated.updatedAt
        )
    }

    /// The span as a window, when the trip has both ends.
    public var span: ClosedRange<Date>? {
        guard let spanStart, let spanEnd, spanStart <= spanEnd else { return nil }
        return spanStart...spanEnd
    }

    /// The contract writes the cover inline with exactly the fields of a library row, so the
    /// generator gives it a type of its own; one encode-decode turns it into the library's row
    /// without this file naming the generator's choice of name.
    static func row<Cover: Encodable>(_ cover: Cover?, baseURL: URL) -> LibraryRow? {
        guard let cover,
            let data = try? JSONEncoder().encode(cover),
            let item = try? JSONDecoder().decode(
                Components.Schemas.AttachmentListItem.self, from: data)
        else { return nil }
        return LibraryRow(item, baseURL: baseURL)
    }
}

/// A change to a trip's record. Each field is left as it is unless it says otherwise: a left field
/// is ABSENT from the body, so the server keeps it; a cleared one is sent as an explicit `null`,
/// which is how the server is told to empty it.
public struct TripPatch: Sendable, Hashable {
    public enum Field<Value: Sendable & Hashable>: Sendable, Hashable {
        /// Absent from the body: the server keeps the value.
        case leave
        /// Sent as the value.
        case set(Value)
        /// Sent as `null`: the server empties the field.
        case clear

        var value: Value? {
            if case .set(let value) = self { return value }
            return nil
        }
    }

    /// The title's change. A title cannot be cleared — the server refuses a trip without one (422)
    /// — so it is not offered.
    public enum TitleField: Sendable, Hashable {
        case leave
        case set(String)

        var value: String? {
            if case .set(let value) = self { return value }
            return nil
        }
    }

    public var title: TitleField
    public var tag: Field<String>
    public var spanStart: Field<Date>
    public var spanEnd: Field<Date>
    public var tz: Field<String>
    public var cover: Field<String>

    public init(
        title: TitleField = .leave,
        tag: Field<String> = .leave,
        spanStart: Field<Date> = .leave,
        spanEnd: Field<Date> = .leave,
        tz: Field<String> = .leave,
        cover: Field<String> = .leave
    ) {
        self.title = title
        self.tag = tag
        self.spanStart = spanStart
        self.spanEnd = spanEnd
        self.tz = tz
        self.cover = cover
    }

    /// The body's wire names of the cleared fields, for `ExplicitNulls`; read from the generated
    /// body's own coding keys, so they are the schema's names.
    var clearedKeys: Set<String> {
        typealias Key = Components.Schemas.CollectionPatch.CodingKeys
        let fields: [(Bool, Key)] = [
            (tag == .clear, .tag),
            (spanStart == .clear, .spanStart),
            (spanEnd == .clear, .spanEnd),
            (tz == .clear, .tz),
            (cover == .clear, .coverAttachmentUid),
        ]
        return Set(fields.filter { $0.0 }.map { $0.1.rawValue })
    }

    var body: Components.Schemas.CollectionPatch {
        .init(
            coverAttachmentUid: cover.value,
            spanEnd: spanEnd.value,
            spanStart: spanStart.value,
            tag: tag.value,
            title: title.value,
            tz: tz.value
        )
    }
}

/// A create, frozen when it is submitted: its body and its idempotency key travel together, and it
/// belongs to the identity it was made under. A retry sends this same value again; editing the
/// form makes a new one, with a new key.
public struct NewTripRequest: Sendable, Hashable {
    public let scope: TimelineSnapshotIdentity
    public let idempotencyKey: String
    public let title: String
    /// Part of the request's identity: the same key under another kind is another create, which
    /// the store refuses while the first is out.
    public let kind: Trip.Kind
    public let tag: String?
    public let spanStart: Date?
    public let spanEnd: Date?
    public let tz: String?

    public init(
        scope: TimelineSnapshotIdentity,
        title: String,
        kind: Trip.Kind = .trip,
        tag: String? = nil,
        spanStart: Date? = nil,
        spanEnd: Date? = nil,
        tz: String? = nil,
        idempotencyKey: String = UUID().uuidString
    ) {
        self.scope = scope
        self.idempotencyKey = idempotencyKey
        self.title = title
        self.kind = kind
        self.tag = tag
        self.spanStart = spanStart
        self.spanEnd = spanEnd
        self.tz = tz
    }

    /// The kind is always sent, a trip's too: the server's default is not relied on.
    var body: Components.Schemas.CollectionCreate {
        let kind: Components.Schemas.CollectionCreate.KindPayload =
            switch self.kind {
            case .trip: .trip
            case .album: .album
            }
        return .init(
            idempotencyKey: idempotencyKey,
            kind: kind,
            spanEnd: spanEnd,
            spanStart: spanStart,
            tag: tag,
            title: title,
            tz: tz
        )
    }
}

/// What one removal or add-back batch did (`TripMemberStore.remove`).
public struct TripBatchOutcome: Sendable, Equatable {
    /// The pictures whose request the server acknowledged, in the order sent. Each one is done.
    public var done: [String]
    /// Why the batch stopped before its last picture, or nil when every one went.
    public var stopped: TripStore.Failure?
    /// Whether the record was read again afterwards. False: the exclusions stand, and the count and
    /// cover are stale until the next refresh.
    public var recordFresh: Bool

    public init(done: [String], stopped: TripStore.Failure?, recordFresh: Bool) {
        self.done = done
        self.stopped = stopped
        self.recordFresh = recordFresh
    }
}

/// What one Add to Album did (`TripStore.addMembers`), summed over its chunks: the server's
/// answer per picture, and what stopped the chunks that were never answered.
public struct AlbumAddOutcome: Sendable, Equatable {
    /// How many pictures were asked for.
    public var asked: Int
    /// Members now, by this add.
    public var added: [String] = []
    /// Members already; nothing was written.
    public var alreadyMember: [String] = []
    /// Answered but not added: not visible to the caller, on no memo, or a write that failed.
    public var notAdded: [String] = []
    /// Why the chunks after the last answered one were not, or nil when every chunk was.
    public var stopped: TripStore.Failure?

    public init(asked: Int) { self.asked = asked }

    /// How many pictures the server answered for.
    public var answered: Int { added.count + alreadyMember.count + notAdded.count }
    /// How many were never answered, because a chunk failed or the add lost its authority.
    public var unanswered: Int { max(0, asked - answered) }

    /// Whether the outcome leaves the picture a member of the album.
    static func isMember(_ outcome: String) -> Bool {
        outcome == "added" || outcome == "alreadyMember"
    }

    mutating func apply(_ outcome: String, to uid: String) {
        switch outcome {
        case "added": added.append(uid)
        case "alreadyMember": alreadyMember.append(uid)
        default: notAdded.append(uid)
        }
    }
}

/// Where a trip's members stand on this device.
public enum TripMemberState: Sendable, Equatable {
    case notLoaded
    case draining
    /// The member route said there is nothing after the last page read.
    case complete
    /// The drain stopped at the cap with more on the server.
    case truncated
}

/// What a trip's members add up to: the server's count, the taken extrema of the drained rows,
/// and the cover the card shows.
public struct TripMemberSummary: Sendable, Equatable {
    public var count: Int
    public var firstTaken: Date?
    public var lastTaken: Date?
    public var cover: LibraryRow?
    /// Which picture is the cover. It names one `cover` cannot hold when an automatic
    /// collection's carried cover lies past a truncated drain: the screen keeps drawing the
    /// thumbnail the card carried rather than swapping to a drained row (MEMNG-817).
    public var coverUid: String?
    /// Whether the drain behind this summary read to the end of the listing. Short of it,
    /// `lastTaken` is only the last row read, and an automatic collection's count is its card's.
    public var complete: Bool

    public init(
        count: Int, firstTaken: Date?, lastTaken: Date?, cover: LibraryRow?,
        coverUid: String? = nil, complete: Bool = true
    ) {
        self.count = count
        self.firstTaken = firstTaken
        self.lastTaken = lastTaken
        self.cover = cover
        self.coverUid = coverUid ?? cover?.id
        self.complete = complete
    }
}

/// The Removed sheet's list: exact, or not available — never approximate.
public enum TripRemovedState: Sendable, Equatable {
    case notRequested
    case loading
    /// Every candidate the server does not list as a member, oldest first.
    case exact([LibraryRow])
    /// The member drain was truncated or no longer belongs to the store's revision.
    case unavailable
}
