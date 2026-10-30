import Foundation
import MemosAPI

/// A guest pass of a collection (memos-ng 2.9.0, `/api/passes`): the door a guest's phone walks
/// through to add pictures to one trip, without an account.
public struct TripPass: Sendable, Equatable, Identifiable {
    public enum Scope: String, Sendable, Hashable, CaseIterable {
        /// Guests add pictures.
        case contribute
        /// Guests add pictures and may also see the trip.
        case contributeAndView = "contribute_view"
    }

    public enum State: String, Sendable, Hashable {
        case active, expired, revoked
    }

    public var uid: String
    public var label: String
    public var scope: Scope
    public var state: State
    public var expiresAt: Date
    public var maxDevices: Int
    public var deviceCount: Int
    /// The pass's epoch on the server, raised by every change to it.
    public var version: Int
    public var revokedAt: Date?

    public var id: String { uid }

    public init(
        uid: String, label: String, scope: Scope = .contribute, state: State = .active,
        expiresAt: Date, maxDevices: Int, deviceCount: Int = 0, version: Int = 1,
        revokedAt: Date? = nil
    ) {
        self.uid = uid
        self.label = label
        self.scope = scope
        self.state = state
        self.expiresAt = expiresAt
        self.maxDevices = maxDevices
        self.deviceCount = deviceCount
        self.version = version
        self.revokedAt = revokedAt
    }

    init(_ out: Components.Schemas.PassOut) {
        self.init(
            uid: out.uid, label: out.label,
            scope: Scope(rawValue: out.scope.rawValue) ?? .contribute,
            // A state this build cannot name is treated as the one that grants nothing.
            state: State(rawValue: out.state.rawValue) ?? .revoked,
            expiresAt: out.expiresAt, maxDevices: out.maxDevices, deviceCount: out.deviceCount,
            version: out.version, revokedAt: out.revokedAt)
    }
}

/// One phone or browser that walked through a pass.
public struct TripPassDevice: Sendable, Equatable, Identifiable {
    public enum Platform: String, Sendable, Hashable {
        case web, clip, app
    }

    public var uid: String
    public var displayName: String
    /// Nil for a platform this build does not know.
    public var platform: Platform?
    public var firstSeen: Date
    public var lastSeen: Date?
    public var uploadsCount: Int
    public var bytesTotal: Int
    public var revoked: Bool

    public var id: String { uid }

    public init(
        uid: String, displayName: String, platform: Platform?, firstSeen: Date,
        lastSeen: Date? = nil, uploadsCount: Int = 0, bytesTotal: Int = 0, revoked: Bool = false
    ) {
        self.uid = uid
        self.displayName = displayName
        self.platform = platform
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.uploadsCount = uploadsCount
        self.bytesTotal = bytesTotal
        self.revoked = revoked
    }

    init(_ out: Components.Schemas.PassDeviceOut) {
        self.init(
            uid: out.uid, displayName: out.displayName,
            platform: Platform(rawValue: out.platform.rawValue), firstSeen: out.firstSeen,
            lastSeen: out.lastSeen, uploadsCount: out.uploadsCount, bytesTotal: out.bytesTotal,
            revoked: out.revoked)
    }
}

/// A picture that came in through one of the collection's passes.
public struct TripContribution: Sendable, Equatable, Identifiable {
    public var attachmentUid: String
    public var memoUid: String
    /// The pass it came through — what a moderation call is addressed to.
    public var passUid: String
    public var contributorName: String?
    public var deviceUid: String?
    public var caption: String?
    /// Hidden from the collection; the picture itself still exists.
    public var hidden: Bool
    public var createdAt: Date

    public var id: String { attachmentUid }

    public init(
        attachmentUid: String, memoUid: String, passUid: String, contributorName: String? = nil,
        deviceUid: String? = nil, caption: String? = nil, hidden: Bool = false, createdAt: Date
    ) {
        self.attachmentUid = attachmentUid
        self.memoUid = memoUid
        self.passUid = passUid
        self.contributorName = contributorName
        self.deviceUid = deviceUid
        self.caption = caption
        self.hidden = hidden
        self.createdAt = createdAt
    }

    init(_ out: Components.Schemas.ContributionOut, pass: String) {
        self.init(
            attachmentUid: out.attachmentUid, memoUid: out.memoUid, passUid: pass,
            contributorName: out.contributorName, deviceUid: out.deviceUid, caption: out.caption,
            hidden: out.hidden, createdAt: out.createdAt)
    }
}

/// What Invite Guests sends: the pass as the owner set it up on the sheet.
public struct TripPassDraft: Sendable, Hashable {
    /// The server's bounds (`PassCreate`): a label of 1–255 characters, 1–200 devices.
    public static let labelLimit = 255
    public static let deviceRange = 1...200
    /// The server's own default cap.
    public static let defaultDevices = 30

    public var label: String
    public var scope: TripPass.Scope
    public var expiresAt: Date
    public var maxDevices: Int

    public init(
        label: String, scope: TripPass.Scope = .contribute, expiresAt: Date,
        maxDevices: Int = TripPassDraft.defaultDevices
    ) {
        self.label = label
        self.scope = scope
        self.expiresAt = expiresAt
        self.maxDevices = maxDevices
    }

    /// The sheet's opening draft for `trip`: named after it, expiring as the server would choose.
    public static func opening(for trip: Trip, now: Date) -> TripPassDraft {
        TripPassDraft(label: trip.title, expiresAt: defaultExpiry(spanEnd: trip.spanEnd, now: now))
    }

    /// Fourteen days after the trip ends, which is when the server's own default lands. A trip
    /// with no span, or one that ended so long ago that date has passed, gets thirty days from
    /// now instead — the server refuses an expiry that is not in the future.
    public static func defaultExpiry(spanEnd: Date?, now: Date) -> Date {
        let day: TimeInterval = 24 * 60 * 60
        if let spanEnd {
            let afterTrip = spanEnd.addingTimeInterval(14 * day)
            if afterTrip > now { return afterTrip }
        }
        return now.addingTimeInterval(30 * day)
    }

    /// The label as it is sent, or nil when it says nothing or is longer than the server takes.
    public var sentLabel: String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // The server counts code points (a Python `len`), not what reads as one character.
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= Self.labelLimit else { return nil }
        return trimmed
    }

    /// Whether the server would take this draft at `now`.
    public func isSendable(at now: Date) -> Bool {
        sentLabel != nil && expiresAt > now && Self.deviceRange.contains(maxDevices)
    }
}

/// A pass as it was issued: the one answer that carries its guest URL. The server keeps only a
/// hash of the secret inside that URL, so this value is the only copy there will ever be.
public struct IssuedTripPass: Sendable, Equatable {
    public var pass: TripPass
    /// What the QR code encodes and the share row hands over.
    public var url: URL

    public init(pass: TripPass, url: URL) {
        self.pass = pass
        self.url = url
    }
}

/// What the Guest Uploads inbox does to the chosen pictures.
public enum TripModeration: String, Sendable, Hashable {
    case hide, unhide, remove
}

/// How a moderation call went, picture by picture, counted.
public struct TripModerationOutcome: Sendable, Equatable {
    /// Pictures the server changed as asked.
    public var applied: Int
    /// Pictures it could not change: not this pass's, or its files could not be removed.
    public var failed: Int

    public init(applied: Int = 0, failed: Int = 0) {
        self.applied = applied
        self.failed = failed
    }
}
