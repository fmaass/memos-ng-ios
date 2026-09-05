import CryptoKit
import Foundation

/// Who this device was signed in as the last time a server said so — and which credential it said
/// it about.
///
/// It is what lets the app open before the network answers. A stored token alone is not enough to
/// show anybody a timeline: the toolbar and Settings draw a name, and seeding one from the licence
/// (a server and a subject, nothing more) would put a fabricated identity on screen.
///
/// Its own `Codable` DTO rather than a `Codable` `User`, deliberately. The domain models are the
/// app's vocabulary and they change with the API; a file that outlives a launch is a FORMAT, and a
/// format that moves whenever a model does is a migration nobody planned. `formatVersion` is what
/// carries a shape change, and bumping it is the mandatory companion of one.
///
/// The `credentialFingerprint` is the whole of its safety. An account switch on the SAME server
/// stores the new token and writes this file as two steps, and a process that dies between them
/// leaves a file naming A beside a credential belonging to B — one server, so nothing else on the
/// device can tell them apart, and publishing A's licence next to B's token is a capture posted
/// into the wrong account. A launch that finds a fingerprint which does not match the stored token
/// is exactly that state, and it declines to admit anybody.
public struct LastKnownUser: Codable, Sendable, Equatable {
    /// What this file's shape is. Read on every launch: a file written by a version that shaped it
    /// differently is not read, it is ignored, and the launch waits on the server as it always did.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var subject: String
    public var displayName: String?
    public var email: String?
    public var role: String
    public var authKind: String
    /// The server this identity belongs to, as `ServerConfiguration.baseURL.absoluteString`. A
    /// subject means nothing across servers.
    public var serverBaseURL: String
    /// SHA-256 of the credential the server answered `whoami` FOR — never of a value read back
    /// out of storage, which is a different question with the same-looking answer.
    public var credentialFingerprint: String

    public init(
        formatVersion: Int = LastKnownUser.currentFormatVersion,
        subject: String,
        displayName: String? = nil,
        email: String? = nil,
        role: String,
        authKind: String,
        serverBaseURL: String,
        credentialFingerprint: String
    ) {
        self.formatVersion = formatVersion
        self.subject = subject
        self.displayName = displayName
        self.email = email
        self.role = role
        self.authKind = authKind
        self.serverBaseURL = serverBaseURL
        self.credentialFingerprint = credentialFingerprint
    }

    public init(user: User, serverBaseURL: URL, credentialFingerprint: String) {
        self.init(
            subject: user.subject,
            displayName: user.displayName,
            email: user.email,
            role: user.role,
            authKind: user.authKind,
            serverBaseURL: serverBaseURL.absoluteString,
            credentialFingerprint: credentialFingerprint
        )
    }

    /// The identity to show while the server is being asked about it.
    public var user: User {
        User(
            subject: subject,
            displayName: displayName,
            email: email,
            role: role,
            authKind: authKind
        )
    }

    /// Whether this file describes the credential and server a launch is holding.
    ///
    /// Both halves, always. The server alone is what an interrupted same-server switch passes.
    public func binds(serverBaseURL: URL, token: String) -> Bool {
        formatVersion == Self.currentFormatVersion
            && self.serverBaseURL == serverBaseURL.absoluteString
            && credentialFingerprint == CredentialFingerprint.of(token)
    }
}

/// The one-way name of a credential, so a file can say WHICH token it was written for without
/// holding one.
public enum CredentialFingerprint {
    public static func of(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Where the last-known user is kept.
///
/// A seam rather than a file path, so that a test names its own directory and the suites that
/// know nothing about this file are handed no store at all — the way the account licence is
/// composed by the app and absent everywhere else.
public protocol LastKnownUserStoring: Sendable {
    func read() -> LastKnownUser?
    func write(_ record: LastKnownUser)
    func delete()
}

/// The app container's copy: one JSON file in Application Support.
///
/// Not the keychain — this is not a secret, it is a name and a hash, and a keychain item read on
/// the background-launch path is a fifth thing that can fail there. Not the app group either: the
/// share extension has no session to restore and no business knowing who was signed in beyond the
/// licence it already reads.
///
/// The container's DEFAULT protection class, which on iOS is "complete until first user
/// authentication". `.complete` would be stronger and wrong: this file is read at the very start
/// of a launch the system can perform before anybody has unlocked the phone (a background refresh
/// finishing an upload), and a file that will not open there takes the offline launch away on
/// exactly the path that needed it.
///
/// Excluded from backup, because a restore onto another device brings no keychain item with it
/// (the credential is `ThisDeviceOnly`) and a file naming an identity with no token behind it is
/// the orphan `restore()` has to reconcile.
public struct LastKnownUserFile: LastKnownUserStoring {
    private let url: URL

    public init(directory: URL = .applicationSupportDirectory.appending(path: "session")) {
        self.url = directory.appending(path: "last-known-user.json")
    }

    /// The live one, composed by the app.
    public static func live() -> LastKnownUserFile { LastKnownUserFile() }

    public func read() -> LastKnownUser? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A file that will not decode is a file from another shape of this app. It is IGNORED
        // rather than repaired or deleted: the launch simply waits on the server, which is the
        // answer this whole file is only a shortcut around.
        guard let record = try? JSONDecoder().decode(LastKnownUser.self, from: data),
            record.formatVersion == LastKnownUser.currentFormatVersion
        else { return nil }
        return record
    }

    public func write(_ record: LastKnownUser) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // Atomic, so a launch reading this while it is rewritten reads one version or the other
        // and never half of a fingerprint.
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        // Set AFTER every write: `.atomic` replaces the file with a fresh one, which does not
        // carry the flag its predecessor had.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(excluded)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
