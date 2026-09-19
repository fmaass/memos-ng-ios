import Darwin
import Foundation

/// Why a lease on the outbox root could not be taken.
///
/// Two, because they say different things about the world. `contended` is another holder, which is
/// the lock working: somebody is in the tree and this pass waits its turn. `unavailable` is the
/// lock itself not working here, which says nothing whatever about who else is in the tree — and
/// is precisely why it may not be read as "nobody is".
public enum OutboxLockFailure: Sendable, Equatable {
    case contended
    case unavailable(Int32)
}

/// Which way the root is being held: shared for a capture, exclusive for a sweep.
enum OutboxLockMode: Sendable {
    case shared
    case exclusive

    /// Non-blocking in both directions. A queue that blocks on this lock would park the share
    /// extension behind whatever the containing app is doing, and an extension has no time to
    /// spend waiting: it is killed, not asked.
    var operation: Int32 {
        switch self {
        case .shared: LOCK_SH | LOCK_NB
        case .exclusive: LOCK_EX | LOCK_NB
        }
    }
}

/// What one acquisition answered.
enum OutboxLockAcquisition {
    case leased(OutboxLease)
    case refused(OutboxLockFailure)
}

/// A held advisory lock, released by closing the descriptor it was taken on.
///
/// `flock(2)` attaches a lock to the open file DESCRIPTION rather than to the process, so two
/// independent `open()` calls conflict with each other exactly as two processes do. That is what
/// makes the app-versus-extension exclusion provable from inside one test — a second descriptor is
/// a faithful stand-in for a second process — and it is why `fcntl` record locks are not used
/// here: those are per process, and closing any descriptor of the file drops all of them.
///
/// Not `Sendable`, deliberately. One descriptor and a release-once flag are exactly the mutable
/// state that would have to be lied about to make this shared; it is handed from one isolation to
/// the next by transfer instead.
final class OutboxLease {
    private let descriptor: Int32
    private var isReleased = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Idempotent, because `deinit` calls it too: a descriptor closed twice is a descriptor number
    /// some other file has since been given.
    func release() {
        guard !isReleased else { return }
        isReleased = true
        close(descriptor)
    }

    deinit {
        release()
    }
}

/// The outbox root's cross-process advisory lock.
///
/// The file sits at the ROOT, beside the four directories and inside none of them, so the sweep's
/// own listings — `media` and `chunks` — can never see it. The kernel drops a lease when its
/// process dies, so a share extension that is killed mid-capture cannot lock the sweep out.
struct OutboxLock: Sendable {
    private let url: URL
    /// `flock(2)`, behind a seam. A filesystem that does not implement locking is a branch no real
    /// one on this machine can be asked for, and it is the branch both sides have to degrade
    /// closed on, so the tests reach it here.
    private let call: @Sendable (Int32, Int32) -> Int32

    /// `flock` names the record-lock STRUCT out of `fcntl.h` as well as this call, and the bare
    /// name resolves to the struct. The local's type is what picks the function.
    static let systemFlock: @Sendable (Int32, Int32) -> Int32 = { descriptor, operation in
        let call: @convention(c) (Int32, Int32) -> Int32 = flock
        return call(descriptor, operation)
    }

    init(url: URL, flock: @escaping @Sendable (Int32, Int32) -> Int32 = OutboxLock.systemFlock) {
        self.url = url
        self.call = flock
    }

    /// Puts the file there, so both processes lease the same inode from the first launch on.
    ///
    /// Best effort: `acquire` opens with `O_CREAT` as well, and a root that cannot take this file
    /// cannot take the four directories beside it either — which is where that failure is reported.
    func createFile() {
        let descriptor = openDescriptor()
        if descriptor >= 0 { close(descriptor) }
    }

    func acquire(_ mode: OutboxLockMode) -> sending OutboxLockAcquisition {
        let descriptor = openDescriptor()
        guard descriptor >= 0 else { return .refused(.unavailable(errno)) }
        if call(descriptor, mode.operation) == 0 {
            return .leased(OutboxLease(descriptor: descriptor))
        }
        // Read before anything else can overwrite it, and the descriptor closed after, because
        // `close` is entitled to set it too.
        let code = errno
        close(descriptor)
        return .refused(code == EWOULDBLOCK ? .contended : .unavailable(code))
    }

    private func openDescriptor() -> Int32 {
        url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        }
    }
}
