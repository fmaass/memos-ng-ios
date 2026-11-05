import Foundation

/// The upload-only capture grant the app mints in the foreground and leaves beside the licence,
/// so the share extension can open a capture's uploads itself (MEMNG-938).
///
/// The extension holds no session token and never will — the device token lives in the app's own
/// keychain group. What it may hold is this: a credential the server accepts on the upload
/// protocol only (POST /api/uploads, PATCH and HEAD on one upload) and refuses everywhere else,
/// that expires within a day and dies with the device token that minted it.
///
/// It is STAMPED with the licence issue it was minted under — the account epoch the extension can
/// see. A capture is enqueued under one issue of the licence; a grant minted under any other issue
/// is never handed to it, whatever the binding says (`credential(enqueuedUnder:at:)`).
public struct PublishedCaptureGrant: Sendable, Equatable, Codable {
    /// The grant's row on the server: what Manage Tokens lists it as, and what the app revokes.
    public let id: Int
    public let token: String
    public let expiresAt: Date
    public let binding: AccountBinding
    /// The licence issue (`PublishedLicence.incarnation`) the app held when it ASKED for this
    /// grant. Never nil: a licence without an issue fences nothing, so no grant is minted onto one.
    public let incarnation: UUID

    public init(id: Int, token: String, expiresAt: Date, binding: AccountBinding, incarnation: UUID)
    {
        self.id = id
        self.token = token
        self.expiresAt = expiresAt
        self.binding = binding
        self.incarnation = incarnation
    }

    /// How long a grant must still have left to be handed to a capture. A grant that lapses while
    /// the bodies are on their way fails them half sent, and the app's lane would send them again;
    /// a few minutes of margin costs nothing, because a foreground re-mints once less than
    /// `remintBelow` is left.
    public static let minimumRemaining: TimeInterval = 5 * 60

    /// How long a grant must still have left for a foreground to keep it rather than mint again.
    ///
    /// Every mint revokes the grant before it, and an extension upload still running under that
    /// one is refused and falls back to the app. Half the server's 24 hours: a foreground leaves
    /// the extension at least twelve hours of grant, and re-mints at most twice a day.
    public static let remintBelow: TimeInterval = 12 * 60 * 60

    /// The credential a capture enqueued under `licence` may upload with, or nil.
    ///
    /// Every condition is about the capture, not about whoever is signed in now: the grant's issue
    /// must BE the issue the capture was admitted under (a grant of issue n is never used for a
    /// capture enqueued under issue n+1), its binding must be the capture's, and it must not be
    /// about to lapse.
    public func credential(enqueuedUnder licence: PublishedLicence, at now: Date)
        -> ShareUploadCredential?
    {
        guard let issue = licence.incarnation, issue == incarnation,
            binding == licence.binding,
            expiresAt.timeIntervalSince(now) > Self.minimumRemaining
        else { return nil }
        // The grant's own id is the epoch: every mint rotates it, so the number names exactly one
        // grant, and `CaptureGrantStore.stillStands` asks whether the file still holds that one.
        return ShareUploadCredential(token: token, epoch: id, binding: binding)
    }

    private enum CodingKeys: String, CodingKey {
        case id, token, expiresAt, serverBaseURL, ownerSubject, incarnation
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(Int.self, forKey: .id)
        token = try fields.decode(String.self, forKey: .token)
        expiresAt = try fields.decode(Date.self, forKey: .expiresAt)
        binding = AccountBinding(
            serverBaseURL: try fields.decode(URL.self, forKey: .serverBaseURL),
            ownerSubject: try fields.decode(String.self, forKey: .ownerSubject)
        )
        incarnation = try fields.decode(UUID.self, forKey: .incarnation)
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id)
        try fields.encode(token, forKey: .token)
        try fields.encode(expiresAt, forKey: .expiresAt)
        try fields.encode(binding.serverBaseURL, forKey: .serverBaseURL)
        try fields.encode(binding.ownerSubject, forKey: .ownerSubject)
        try fields.encode(incarnation, forKey: .incarnation)
    }
}
