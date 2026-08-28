import Foundation

/// The token every request presents, in the ONE place a renewal can move it.
///
/// `BearerAuthMiddleware` reads its credential through a closure rather than holding a copy,
/// precisely so that it can change underneath a client that is already built. Until renewal there
/// was nothing to move: every closure this app handed the factory captured a `let` by value, which
/// is the stale copy that comment refuses, one level further out.
///
/// It matters more here than anywhere else in the app. A renewal DESTROYS the presenting token in
/// the same statement that mints its successor, so from the moment the server answers, any client
/// still carrying the old one is carrying a credential that no longer exists. Rebuilding them is
/// not available: the session hands its client to stores that keep it for the life of the session
/// and nothing collects them again. So the value moves and the clients stay.
///
/// A locked class rather than an actor, and that is the whole reason it is a type at all: the
/// middleware reads this on EVERY request, from whatever executor the transport is running on, and
/// an actor would put a suspension point on the hot path of every call the app makes.
public final class PresentedCredential: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String

    public init(_ token: String) {
        self.token = token
    }

    /// What the next request will carry.
    public var current: String { lock.withLock { token } }

    /// The successor, in place of the token the server has just destroyed.
    public func replace(with token: String) {
        lock.withLock { self.token = token }
    }
}
