import Darwin
import Foundation
import MemosOutbox

enum Fixture {
    static let server = URL(string: "https://memos.example.invalid")!

    static func binding(server: URL = Fixture.server, owner: String = "fabian") -> AccountBinding {
        AccountBinding(serverBaseURL: server, ownerSubject: owner)
    }

    /// One grant, fixed. A commit reads the licence several times, and a fresh issue per read would
    /// refuse every share in this bundle for a revocation nobody performed.
    static let grant = UUID(uuidString: "1D0F5A7C-2B44-4E19-9C6A-0F2E7B3D8A51")!

    static func licence(
        for binding: AccountBinding = Fixture.binding(),
        under grant: UUID = Fixture.grant
    ) -> PublishedLicence {
        PublishedLicence(binding: binding, incarnation: grant)
    }

    /// A temporary directory that the caller removes.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "share-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file whose bytes are known, so a copy can be compared against them exactly.
    static func file(in directory: URL, named name: String, bytes count: Int) throws -> URL {
        let url = directory.appending(path: name)
        try content(count).write(to: url)
        return url
    }

    /// Deterministic, non-repeating-per-byte content: a truncated copy produces different bytes.
    static func content(_ count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0..<count {
            data.append(UInt8((index &* 31 &+ 7) % 251))
        }
        return data
    }
}

/// A clock that only moves when something sleeps on it, and remembers every sleep it was asked for.
///
/// It is the whole reason the wait is testable: the deadline is read from the same object the sleep
/// advances, so thirty waits of a hundred milliseconds spend three seconds of budget and no time at
/// all. `@unchecked Sendable` over a lock rather than an actor, because the wait reads `now`
/// synchronously and an actor would make that an await inside the thing being measured.
final class FakeWaitClock: OutboxWaitClock, @unchecked Sendable {
    private let mutex = NSLock()
    private var instant = ContinuousClock.now
    private var taken: [Duration] = []
    /// Run inside `sleep`, with the number of sleeps taken so far — the seam a test drops a held
    /// lock through, at the exact poll it means to drop it at rather than after a race with one.
    private let onSleep: @Sendable (Int) -> Void

    init(onSleep: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.onSleep = onSleep
    }

    var now: ContinuousClock.Instant { mutex.withLock { instant } }

    /// Every sleep in order, so a test can say how long each wait was as well as how many there
    /// were: a bound proved by a count alone is a bound that any interval satisfies.
    var sleeps: [Duration] { mutex.withLock { taken } }

    func sleep(for duration: Duration) async throws {
        let count = mutex.withLock {
            taken.append(duration)
            instant = instant.advanced(by: duration)
            return taken.count
        }
        onSleep(count)
    }
}

/// The outbox root held the way the OTHER process holds it: a descriptor this test opened itself
/// and the real `flock(2)`, never the repository's own seam.
///
/// `flock` attaches a lock to the open file DESCRIPTION rather than to the process, so a second
/// descriptor taken here conflicts with the repository's acquisition exactly as the app in another
/// process would — which is the only reason a test in this bundle can stand in for it at all.
final class ForeignRootLock: @unchecked Sendable {
    private let descriptor: Int32
    private let mutex = NSLock()
    private var isReleased = false

    /// Nil when the root has no lock file yet, or when the exclusive hold was refused. Both are a
    /// broken premise for a test whose subject is what happens WHILE it is held, so neither may
    /// pass silently for one that simply never took it.
    init?(exclusiveOn root: URL) {
        let path = root.appending(path: ".lock").path(percentEncoded: false)
        descriptor = Darwin.open(path, O_RDWR)
        guard descriptor >= 0 else { return nil }
        // The bare name `flock` resolves to the record-lock struct out of `fcntl.h`; the local's
        // type is what picks the call.
        let call: @convention(c) (Int32, Int32) -> Int32 = flock
        guard call(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
    }

    /// Idempotent, because a test drops the hold in the middle of a run and still defers the
    /// release: a descriptor closed twice is a descriptor number some other file has since been
    /// given.
    func release() {
        let shouldClose = mutex.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
        if shouldClose { close(descriptor) }
    }

    deinit {
        release()
    }
}

/// The licence file as a share sees it: a value the app can revoke and grant again between two of
/// this commit's reads, which is exactly what a three-second wait made possible.
final class StandingLicence: @unchecked Sendable {
    private let mutex = NSLock()
    private var value: PublishedLicence?

    init(_ value: PublishedLicence?) {
        self.value = value
    }

    /// What `ShareIngest.commit` is handed. Every read goes through here, so a change made between
    /// two attempts is a change the commit can actually see.
    func read() -> PublishedLicence? { mutex.withLock { value } }

    /// Forgotten, and granted again to the SAME account: the identical binding under a grant that
    /// is not the one the share was admitted under.
    func reissue() {
        mutex.withLock {
            value = value.map { PublishedLicence(binding: $0.binding, incarnation: UUID()) }
        }
    }

    func replace(with licence: PublishedLicence?) {
        mutex.withLock { value = licence }
    }
}
