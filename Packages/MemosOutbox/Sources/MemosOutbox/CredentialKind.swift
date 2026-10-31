import Foundation

/// Whose credential a queued capture travels under: the household member's own session, or a
/// guest's trip pass.
///
/// The two never share anything — not a Keychain account, not an epoch, not a queue, not a server.
/// A guest credential presented to the home server, or a member credential presented to the guest
/// door, is the leak this type exists to make impossible to write by accident: every request
/// builder that differs per kind takes it explicitly, and a capture carries it in its binding, so
/// every fence that compares bindings compares kinds too.
public enum CredentialKind: String, Codable, Sendable, Equatable, CaseIterable {
    case member
    case guest
}
