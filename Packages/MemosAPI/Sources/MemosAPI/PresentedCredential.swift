import Foundation

/// The token every request presents, in the ONE place a renewal can move it — and which generation
/// of the credential that is.
///
/// `BearerAuthMiddleware` reads its credential through this rather than holding a copy, precisely
/// so that it can change underneath a client that is already built. A renewal DESTROYS the
/// presenting token in the same statement that mints its successor, so from the moment the server
/// answers, any client still carrying the old one is carrying a credential that no longer exists.
/// Rebuilding them is not available: the session hands its client to stores that keep it for the
/// life of the session and nothing collects them again. So the value moves and the clients stay.
///
/// The EPOCH is what makes that swap safe rather than merely possible. Requests that left before
/// it are still in the air, and the server will refuse every one of them — it destroyed the token
/// they carry. Those 401s say nothing whatever about the successor this device is now holding, and
/// obeying them would sign somebody out of a session they renewed a second ago. So each request
/// remembers which generation it presented, and a refusal of a superseded one is not allowed to
/// reach the rule that ends sessions.
///
/// It lives in this package, beside the middleware that reads it, because that is the only code
/// that has to see a request's epoch at the moment its answer arrives.
///
/// A locked class rather than an actor, and that is the whole reason it is a type at all: the
/// middleware reads this on EVERY request, from whatever executor the transport is running on, and
/// an actor would put a suspension point on the hot path of every call the app makes.
public final class PresentedCredential: @unchecked Sendable {
    /// One generation of the credential: what a request carried, and which generation that was.
    public struct Snapshot: Sendable, Equatable {
        public let token: String
        public let epoch: UInt64
    }

    private let lock = NSLock()
    private var token: String
    private var generation: UInt64 = 0

    public init(_ token: String) {
        self.token = token
    }

    /// A credential that presents nothing. The exchange that gets a device its FIRST token has to
    /// be anonymous — presenting one there would be circular — and an empty token is never
    /// attached, so this is that state rather than a special case in the middleware.
    public static var anonymous: PresentedCredential { PresentedCredential("") }

    /// What the next request will carry.
    public var current: String { lock.withLock { token } }

    /// Read as ONE value: the token and its generation have to come from the same instant, or a
    /// request could report an epoch belonging to a different token than the one it sent.
    public func presented() -> Snapshot {
        lock.withLock { Snapshot(token: token, epoch: generation) }
    }

    /// The successor, in place of the token the server has just destroyed.
    public func replace(with token: String) {
        lock.withLock {
            self.token = token
            generation += 1
        }
    }

    /// Whether a request that presented `epoch` is still speaking for the credential this device
    /// holds now. False means its answer — including a refusal — is about a token that is gone.
    public func isCurrent(_ epoch: UInt64) -> Bool {
        lock.withLock { epoch == generation }
    }
}

/// A refusal of a credential this device has already replaced.
///
/// Thrown INSTEAD of letting the 401 through, which is the whole of its job. The unauthorized case
/// is the app's one "this session is over" signal, read by the session and by every screen that
/// reports one, and a stale refusal reaching it would end a session that is perfectly alive. As an
/// error of its own it lands in the ordinary failure path — the caller reports it, retries it, or
/// ignores it — and nothing treats it as evidence about the token in hand.
public struct CredentialSuperseded: Error, Equatable, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "That request was made with a credential this device has since replaced."
    }
}
