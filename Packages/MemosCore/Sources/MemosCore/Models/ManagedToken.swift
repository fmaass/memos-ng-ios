import Foundation
import MemosAPI

/// One of the account's personal access tokens, as the management screen sees it.
///
/// A different thing from `DeviceToken`, deliberately. That one is what a bearer may learn about
/// ITSELF — four fields, no id, no siblings — because a device token reaches no further than the
/// credential making the request. This one comes from `/api/pats`, which lists the whole account
/// under the authority of a step-up grant, so it HAS an id: the screen exists to revoke tokens,
/// and a row with no id is a row nothing can act on.
public struct ManagedToken: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let createdAt: Date
    /// `nil` for a token that has authenticated nothing yet — a real state, not a missing value.
    public let lastUsed: Date?
    /// `nil` for a token that never expires, which is what `/api/pats` mints when nobody says
    /// otherwise and what every token created before device tokens is.
    public let expiresAt: Date?

    public init(id: Int, name: String, createdAt: Date, lastUsed: Date?, expiresAt: Date?) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsed = lastUsed
        self.expiresAt = expiresAt
    }
}

extension ManagedToken {
    public init(_ generated: Components.Schemas.PatOut) {
        self.init(
            id: generated.id,
            name: generated.name,
            createdAt: generated.createdAt,
            lastUsed: generated.lastUsed,
            expiresAt: generated.expiresAt
        )
    }

    /// The same row as it arrives from a creation, which carries the plaintext beside it. The two
    /// generated types are separate declarations of the same five fields, so the row is read the
    /// same way from both rather than the screen learning about the difference.
    public init(_ generated: Components.Schemas.PatCreated) {
        self.init(
            id: generated.id,
            name: generated.name,
            createdAt: generated.createdAt,
            lastUsed: generated.lastUsed,
            expiresAt: generated.expiresAt
        )
    }
}

/// A token that has just been created, together with the one and only look anybody gets at it.
///
/// The plaintext exists in exactly one response — the creation's — and is stored nowhere, by the
/// server or by this app. So it is carried apart from the row rather than as a field on it: a
/// `ManagedToken` is what a list is made of and is safe to keep, and the secret is a thing on
/// screen for as long as the screen is, and then gone.
public struct MintedToken: Sendable, Equatable {
    public let token: ManagedToken
    /// Shown once. Not persisted, not logged, and unrecoverable the moment it leaves the screen —
    /// the token itself still works and can still be revoked from the list.
    public let secret: String

    public init(token: ManagedToken, secret: String) {
        self.token = token
        self.secret = secret
    }
}
