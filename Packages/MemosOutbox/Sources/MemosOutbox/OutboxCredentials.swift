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
    /// A REQUIREMENT rather than a defaulted extension. A default of `true` would mean a provider
    /// that simply forgot this silently defeats every `mayStillSend` site in the drain, and the
    /// compiler would say nothing — the one shape of mistake this fence exists to make impossible.
    ///
    /// SYNCHRONOUS on purpose, and asked immediately before a request goes out. An `await` here
    /// would be one more instant for an account switch to land in — which is the whole of what
    /// this exists to catch, since a drain pass outlives the switch that happens during it.
    func isCurrent(_ credentials: OutboxCredentials) -> Bool
}

/// The authority a send is made under, asked at the LAST instant before it goes out.
///
/// It TRAVELS into the executor that performs the effect rather than being checked beside the call
/// that starts it. Between a check on one actor and an effect on another there is a hop, and a hop
/// is a suspension — which is exactly the window an account switch fits into. Checking here means
/// the answer and the send are on the same executor with nothing in between.
///
/// A closure rather than a value, because the question is "is this still true NOW", and a value
/// captured earlier can only answer "was it true then".
public struct SendAuthority: Sendable {
    private let stillCurrent: @Sendable () -> Bool
    private let currentCredential: @Sendable () -> String?

    public init(
        _ stillCurrent: @escaping @Sendable () -> Bool,
        credential: @escaping @Sendable () -> String? = { nil }
    ) {
        self.stillCurrent = stillCurrent
        self.currentCredential = credential
    }

    public func holds() -> Bool { stillCurrent() }

    /// The token to present, read at the SAME instant the verdict is — which is why it lives here
    /// rather than being handed to a request before the hop.
    ///
    /// A renewal moves the token without ending the session, so the incarnation `holds()` answers
    /// on does not move either: a lane that snapshotted its token before suspending would be
    /// cleared to send, and would send the one the server has just destroyed. `nil` where the
    /// lane's credential does not travel this way — the generated client reads its own.
    public func credential() -> String? { currentCredential() }

    /// For the callers with no session behind them — a test double, and the share extension's
    /// lane, which is fenced by the account licence instead.
    public static let unfenced = SendAuthority { true }
}
