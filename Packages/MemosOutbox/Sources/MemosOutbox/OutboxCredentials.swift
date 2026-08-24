import Foundation

/// Who the outbox is allowed to upload as, right now.
///
/// Deliberately NOT `Codable`: the token exists in memory for the length of a drain and nowhere
/// else. `description` is overridden for the same reason — an interpolated credential in a log is
/// a leaked credential.
public struct OutboxCredentials: Sendable, Equatable {
    public var serverBaseURL: URL
    public var ownerSubject: String
    public var token: String

    public init(serverBaseURL: URL, ownerSubject: String, token: String) {
        self.serverBaseURL = serverBaseURL
        self.ownerSubject = ownerSubject
        self.token = token
    }

    public var binding: AccountBinding {
        AccountBinding(serverBaseURL: serverBaseURL, ownerSubject: ownerSubject)
    }
}

extension OutboxCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "OutboxCredentials(server: \(serverBaseURL.absoluteString), owner: \(ownerSubject))"
    }

    public var debugDescription: String { description }
}

/// The one thing the outbox needs from the session it cannot know about itself.
public protocol OutboxCredentialsProviding: Sendable {
    /// The signed-in credential, or nil when nobody is signed in — in which case nothing drains.
    func currentCredentials() async -> OutboxCredentials?
}
