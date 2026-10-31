import Foundation

/// The capture grant's file, beside the licence in the outbox root.
///
/// The app is its only writer, and writes it only from the main actor in the same synchronous step
/// as the fence that admits the write (`SessionStore`). The licence's own lifecycle removes it:
/// `OutboxAccountStore.clear()` and a publish that mints a new issue both delete it, so a sign-out
/// or an account change leaves no grant behind even before the server hears of either.
public struct CaptureGrantStore: Sendable {
    public let url: URL

    public init(root: URL) {
        self.url = root.appending(path: "capture-grant.json")
    }

    public static func live(appGroup: String = OutboxDefaults.appGroup) -> CaptureGrantStore? {
        OutboxRepository.appGroupRoot(appGroup: appGroup).map(CaptureGrantStore.init(root:))
    }

    /// The grant on disk, or nil. A file that does not decode reads as nil: a grant nobody can
    /// parse is not one to present.
    public func current() -> PublishedCaptureGrant? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PublishedCaptureGrant.self, from: data)
    }

    /// Writes the grant whole (atomically), readable only after the first unlock, and outside the
    /// device backup: it is a credential, and a credential in a backup outlives its revocation.
    public func write(_ grant: PublishedCaptureGrant) throws {
        let data = try JSONEncoder().encode(grant)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(excluded)
    }

    /// Removing a grant that is not there is success: what matters is that none is left.
    public func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// The extension's question, asked once the capture is committed: the credential its uploads
    /// may present, or nil — and nil means enqueue-only, the app sends it.
    public func uploadCredential(enqueuedUnder licence: PublishedLicence, now: Date = Date())
        -> ShareUploadCredential?
    {
        current()?.credential(enqueuedUnder: licence, at: now)
    }

    /// Whether the grant numbered `epoch` still stands for a capture enqueued under `licence`:
    /// the licence on disk is still that one, and the grant file still holds that grant. Read
    /// from the files every time — the app is another process and they are the only shared truth.
    /// A sign-out removes both, an account change re-issues the licence, and a re-mint rotates the
    /// grant (the server revokes the one before), so each of those answers no.
    public func stillStands(
        epoch: Int, enqueuedUnder licence: PublishedLicence, standing: PublishedLicence?
    ) -> Bool {
        guard standing == licence, let grant = current() else { return false }
        return grant.id == epoch && grant.incarnation == licence.incarnation
    }
}
