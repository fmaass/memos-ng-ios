import Foundation

/// Which session this device is on, readable from any isolation without an await.
///
/// One number, shared by the objects that have to agree about it. `SessionStore` moves it wherever
/// "who this device is signed in as" changes; the timeline stamps every list it publishes with the
/// value it read when the request went out; and the snapshot writer reads it AGAIN — synchronously,
/// with nothing awaited in between — at the moment it is about to touch the disk. A write whose
/// stamp is not the number this box holds belongs to a session that has ended, and it is refused
/// there rather than anywhere earlier, because "earlier" is exactly where the world gets to change
/// underneath the check.
///
/// A locked class rather than an actor, for the same reason `PresentedCredential` is one: the value
/// has to be read from the writer's executor and from the main actor without either of them
/// suspending, and a suspension between the check and the write is the bug this type exists to make
/// impossible.
public final class SessionEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    public init(_ value: Int = 0) {
        self.value = value
    }

    /// The session everything issued from now belongs to.
    public var current: Int { lock.withLock { value } }

    /// Moved by `SessionStore`, wherever its own session generation moves — they are one fact kept
    /// in two places only because one of them has to be readable without an await.
    public func adopt(_ value: Int) {
        lock.withLock { self.value = value }
    }
}
