import Foundation

/// An upload session a removed capture left open on the server, owed its DELETE (MEMNG-953).
public struct UploadSessionWithdrawal: Codable, Equatable, Sendable {
    public var uploadUID: String
    /// The account the session was opened under — the only one whose DELETE withdraws it. The
    /// server answers 204 for a uid another caller owns and withdraws nothing, so a withdraw sent
    /// under any other account would read as done and leave the session open.
    public var binding: AccountBinding

    public init(uploadUID: String, binding: AccountBinding) {
        self.uploadUID = uploadUID
        self.binding = binding
    }
}

/// The withdraws Remove has queued and the server has not answered yet, kept on disk.
///
/// Remove does not wait for the server: the card goes at once, and a DELETE that cannot be sent
/// now (no network, a busy database, another account signed in) is sent on a later pass. The
/// capture's manifest is the only other record of its upload uids and it is gone by then, so the
/// queue is written BEFORE it goes (`OutboxRepository.withdraw`), and an entry leaves only once
/// the server answered for it. At the root beside the lock file, out of the sweep's reach.
public final class UploadSessionWithdrawals: @unchecked Sendable {
    private let url: URL
    // Recording is the repository's and settling the engine's: the lock makes each
    // read-modify-write one step, so an entry recorded between a pass's read and its settle stays.
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    /// Adds `owed` to what is already owed, each once. False when the write did not land.
    @discardableResult
    func record(_ owed: [UploadSessionWithdrawal]) -> Bool {
        lock.withLock {
            var all = read()
            for item in owed where !all.contains(item) { all.append(item) }
            return write(all)
        }
    }

    /// Everything still owed, oldest first.
    public func pending() -> [UploadSessionWithdrawal] {
        lock.withLock { read() }
    }

    /// Removes what the server answered for; anything recorded since stays.
    func settle(_ answered: [UploadSessionWithdrawal]) {
        guard !answered.isEmpty else { return }
        lock.withLock {
            let rest = read().filter { !answered.contains($0) }
            if rest.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                _ = write(rest)
            }
        }
    }

    private func read() -> [UploadSessionWithdrawal] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([UploadSessionWithdrawal].self, from: data)) ?? []
    }

    private func write(_ all: [UploadSessionWithdrawal]) -> Bool {
        guard let data = try? JSONEncoder().encode(all) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
