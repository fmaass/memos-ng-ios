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

    /// Whether an epoch handed out earlier still names this device's authority.
    ///
    /// The same question as `isCurrent`, asked by something that kept the NUMBER rather than the
    /// whole credential — a chunk answer that comes back in a later pass, a refusal on its way
    /// into the write that acts on it. A REQUIREMENT for the reason `isCurrent` is one: a default
    /// of `true` would let a provider silently defeat the fence.
    ///
    /// SYNCHRONOUS for the same reason, and it matters more here: the caller asks it with the
    /// bytes about to go to disk and nothing awaited in between.
    func stillCurrent(epoch: Int) -> Bool
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
/// What a send actually presented: the token, and the credential generation it belonged to.
///
/// The pair travels together on purpose. A response is classified against the credential that
/// EARNED it, and a token without its generation cannot answer "was this refusal about the
/// credential this device is holding now, or about one it has already replaced" — which is the
/// difference between ending a live session and ignoring a stale 401.
public struct PresentedGrant: Sendable, Equatable {
    public let token: String
    public let epoch: UInt64

    public init(token: String, epoch: UInt64) {
        self.token = token
        self.epoch = epoch
    }
}

/// The pair the last `credential()` handed out, in a box every copy of one authority shares.
///
/// A reference inside a value type, deliberately: `SendAuthority` is copied into the executor that
/// sends, and what the caller needs back afterwards is what THAT copy attached.
private final class AttachedGrant: @unchecked Sendable {
    private let lock = NSLock()
    private var grant: PresentedGrant?

    func record(_ grant: PresentedGrant?) { lock.withLock { self.grant = grant } }
    var current: PresentedGrant? { lock.withLock { grant } }
}

public struct SendAuthority: Sendable {
    private let stillCurrent: @Sendable () -> Bool
    private let currentCredential: @Sendable () -> PresentedGrant?
    private let attached = AttachedGrant()

    public init(
        _ stillCurrent: @escaping @Sendable () -> Bool,
        credential: @escaping @Sendable () -> PresentedGrant? = { nil }
    ) {
        self.stillCurrent = stillCurrent
        self.currentCredential = credential
    }

    public func holds() -> Bool { stillCurrent() }

    /// The credential to present, read at the SAME instant the verdict is — which is why it lives
    /// here rather than being handed to a request before the hop.
    ///
    /// A renewal moves the token without ending the session, so the incarnation `holds()` answers
    /// on does not move either: a lane that snapshotted its token before suspending would be
    /// cleared to send, and would send the one the server has just destroyed. `nil` where the
    /// lane's credential does not travel this way — the generated client reads its own.
    ///
    /// Reading it RECORDS it, so the caller can ask afterwards what its request actually carried.
    public func credential() -> PresentedGrant? {
        let grant = currentCredential()
        attached.record(grant)
        return grant
    }

    /// What the send actually presented — `nil` until something asked.
    ///
    /// This is what a response must be judged against. The epoch the caller read BEFORE the send
    /// is a different number whenever a renewal landed in between, and judging a 401 by it reports
    /// a refusal of the current credential as a refusal of a replaced one — which retains a
    /// session the server has just rejected.
    public func presented() -> PresentedGrant? { attached.current }

    /// The credential generation NOW, without recording it. For asking whether what a send
    /// presented has since been replaced.
    public func currentEpoch() -> UInt64? { currentCredential()?.epoch }

    /// Puts the credential on in the same instant the verdict is read, and never before.
    ///
    /// The caller builds its request with whatever it could see when it started; a renewal landing
    /// in the awaits between there and the send destroys that token without ending the session, so
    /// what the caller wrote down is the one thing that must not go on the wire.
    ///
    /// An authority with no credential behind it (`.unfenced`, and the outbox's, which carries its
    /// own) leaves the request exactly as it arrived.
    public func presenting(_ request: URLRequest) -> URLRequest {
        guard let grant = credential(), !grant.token.isEmpty else { return request }
        var presented = request
        presented.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")
        return presented
    }

    /// For the callers with no session behind them — a test double, and the share extension's
    /// lane, which is fenced by the account licence instead.
    public static let unfenced = SendAuthority { true }
}
