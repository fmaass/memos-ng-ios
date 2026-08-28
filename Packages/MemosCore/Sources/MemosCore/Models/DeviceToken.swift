import Foundation
import MemosAPI

/// What a device may learn about the credential it is already holding.
///
/// There is no id here and no secret, because the contract has neither: a bearer already holds the
/// only token this row describes and has no sibling to act on, so `/api/auth/native/token` answers
/// with the four fields below and nothing else. What is left is exactly the part an owner cannot
/// find out from the phone — how long this device has, and when it last spoke.
public struct DeviceToken: Sendable, Equatable {
    public let name: String
    public let createdAt: Date
    /// `nil` for a token that has authenticated nothing yet — a real state, not a missing value.
    public let lastUsed: Date?
    /// `nil` for a token that never expires. That is also the kind that cannot be renewed, so it is
    /// never a stand-in for "the server did not say".
    public let expiresAt: Date?

    public init(name: String, createdAt: Date, lastUsed: Date?, expiresAt: Date?) {
        self.name = name
        self.createdAt = createdAt
        self.lastUsed = lastUsed
        self.expiresAt = expiresAt
    }
}

extension DeviceToken {
    public init(_ generated: Components.Schemas.NativeTokenOut) {
        self.init(
            name: generated.name,
            createdAt: generated.createdAt,
            lastUsed: generated.lastUsed,
            expiresAt: generated.expiresAt
        )
    }
}

/// What may be sent as a device token's name — the server's own bounds, checked before the request
/// rather than after the 422.
///
/// One rule in one place. The screen offers a field, the session sends the PATCH, and both would
/// otherwise have to agree about what an acceptable name is; a screen that let a 300-character
/// name be typed and a session that sent it would turn a typo into a server error.
public enum DeviceTokenName {
    /// `pats.name` is 255 wide, and `NativeTokenRename` declares `max_length=255` over it — the
    /// same bound `/api/pats` mints under, deliberately.
    public static let maxLength = 255

    /// The name to send, or `nil` when there is none the server would take.
    ///
    /// Trimmed first and measured afterwards, so trailing spaces can neither pass as a name nor
    /// push a legal one over the edge.
    ///
    /// Measured in CODE POINTS, which is the unit the server measures in: pydantic's `max_length`
    /// is checked with Python's `len`, and Python counts code points. Swift's `String.count` counts
    /// grapheme clusters, and the two disagree by a lot on exactly the characters people put in
    /// device names — one flag emoji is one grapheme and two code points, one family emoji is one
    /// grapheme and seven. Counting graphemes here would let a name through that the server then
    /// refuses, for a bound this function exists to have already enforced.
    public static func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= maxLength else { return nil }
        return trimmed
    }
}
