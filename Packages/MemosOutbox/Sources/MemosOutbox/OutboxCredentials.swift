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
    /// Which incarnation of the signed-in session these were acquired under.
    ///
    /// The outbox has no idea what a session is, and it does not need one: this is an opaque
    /// number it carries from the acquisition to the request, and hands back to whoever issued it
    /// to be told whether it still stands. Zero for a provider that has no session behind it — the
    /// share extension, which is fenced by the account licence instead.
    public var epoch: Int

    public init(serverBaseURL: URL, ownerSubject: String, token: String, epoch: Int = 0) {
        self.serverBaseURL = serverBaseURL
        self.ownerSubject = ownerSubject
        self.token = token
        self.epoch = epoch
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

    /// Whether credentials acquired earlier still belong to the session this device is in.
    ///
    /// SYNCHRONOUS on purpose, and asked immediately before a request goes out. An `await` here
    /// would be one more instant for an account switch to land in — which is the whole of what
    /// this exists to catch, since a drain pass outlives the switch that happens during it.
    func isCurrent(_ credentials: OutboxCredentials) -> Bool
}

extension OutboxCredentialsProviding {
    /// A provider with no session behind it cannot be superseded by one.
    public func isCurrent(_ credentials: OutboxCredentials) -> Bool { true }
}
