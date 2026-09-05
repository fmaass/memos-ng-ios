import CryptoKit
import Foundation

/// Which timeline a file on this device is a picture of.
///
/// The pair is the whole of the fence. A uid means nothing across servers and a subject means
/// nothing across accounts, so a snapshot is rendered only for the identity that wrote it — judged
/// against the identity that ISSUED the read, never against whoever happens to be signed in by the
/// time the bytes come back.
public struct TimelineSnapshotIdentity: Sendable, Equatable, Hashable, Codable {
    /// The server the memos were read from.
    public var server: URL
    /// Whose timeline it was: the subject `GET /api/auth/user` answered with.
    public var subject: String

    public init(server: URL, subject: String) {
        self.server = server
        self.subject = subject
    }

    /// The file this identity's snapshot lives in.
    ///
    /// A digest rather than the pair itself: a base URL carries slashes and a subject is whatever
    /// the identity provider issued, and neither is something to build a path component out of. It
    /// is not a secret either — the directory is inside the app container — so the digest is here
    /// for a legal, collision-free name and nothing more.
    var fileName: String {
        let material = Data("\(server.absoluteString)\n\(subject)".utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined() + ".json"
    }
}

/// The last timeline this device saw, as it is written down and read back.
///
/// It is never authoritative: the first answer from the server replaces it whole, and nothing here
/// is a source of pagination cursors — a cursor read back from disk would page into a list this run
/// never asked the server for.
public struct TimelineSnapshot: Sendable, Equatable, Codable {
    /// What a reader has to recognise before it renders anything.
    ///
    /// A change to the SHAPE of any model this envelope carries bumps it in the same change. A file
    /// written under any other number reads as absent, which is what makes a missed bump an empty
    /// timeline that the network fills in rather than a decode that half-succeeds.
    ///
    /// It does not catch everything, and the gap is worth naming: adding an OPTIONAL field decodes
    /// happily from a file written without it. That is a review rule, not something this number can
    /// enforce — a shape change is a shape change even when the compiler tolerates the old bytes.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var identity: TimelineSnapshotIdentity
    /// What the list this picture was taken of was ASKING the server for.
    ///
    /// Only the default query is ever written, and only the default query is ever read back: an
    /// anchored day, a tag filter or a search result is an answer to a question nobody asked again
    /// on the next launch, and rendering one as "the timeline" would open the app on a list the
    /// reader never chose. Carried in the envelope rather than assumed, so a file that says
    /// otherwise — hand-built, or written by a build with a looser rule — is refused at the door.
    public var query: MemoQuery
    /// Which version of the loaded list this is a picture of.
    ///
    /// It counts changes to the list within ONE run and it is what decides, in memory, whether a
    /// write that has just arrived is newer than the one already on the disk: the order two writes
    /// reach the writer in is not something Swift promises (an actor is not a queue, SE-0306), so
    /// the newer picture is the one with the higher number rather than the one that got there
    /// second. Across launches it means nothing — a fresh run starts again at zero and the writer
    /// starts with nothing to compare against, which is right, because the file it finds is the
    /// one this run is about to replace.
    public var revision: Int
    public var writtenAt: Date
    public var memos: [Memo]

    public init(
        formatVersion: Int = TimelineSnapshot.currentFormatVersion,
        identity: TimelineSnapshotIdentity,
        query: MemoQuery,
        revision: Int,
        writtenAt: Date,
        memos: [Memo]
    ) {
        self.formatVersion = formatVersion
        self.identity = identity
        self.query = query
        self.revision = revision
        self.writtenAt = writtenAt
        self.memos = memos
    }
}

/// Where a timeline snapshot lives, and the only thing that puts one there or takes it away.
///
/// `Library/Caches/<bundle id>/timeline/`, because Apple's own definition of purgeable data is
/// "app data that the system can delete without affecting the app's execution and that the app can
/// re-create if it needs" — a regenerable list of the newest memos is exactly that. Caches is
/// excluded from backup for free, and a purge of it never happens while the app is running, so the
/// only way a file disappears underneath this store is between two launches, which is a cold start
/// rather than a fault.
///
/// The container's DEFAULT protection class, deliberately: the same
/// `completeUntilFirstUserAuthentication` the credential in the keychain has, because the app is
/// launched into the background with the device locked and the paths that run then must not meet a
/// file they cannot open. `.complete` would buy nothing this cache needs and would cost a
/// background launch its footing.
///
/// Not the app group: the share extension enqueues captures and has no reason to be able to read
/// anybody's memos.
public struct TimelineSnapshotStore: Sendable {
    /// The most memos a snapshot keeps. Ten pages of twenty (`TimelineStore.pageSize`) is more
    /// than an offline reader scrolls and small enough to encode without a visible pause.
    public static let capacity = 200

    private let root: URL
    private let writeData: @Sendable (Data, URL) throws -> Void

    /// - Parameters:
    ///   - root: the directory the files live in. Injected rather than reached for, so a test
    ///     writes into a temporary directory instead of the running app's container.
    ///   - writeData: the bytes-to-disk step. Injected for one reason: the failure this store has
    ///     to survive — a write that throws, on a full or unwritable disk — is one a test cannot
    ///     produce by asking the file system nicely.
    public init(
        root: URL,
        writeData: @escaping @Sendable (Data, URL) throws -> Void = TimelineSnapshotStore.atomically
    ) {
        self.root = root
        self.writeData = writeData
    }

    /// The store in the app's own container, or nil when there is no bundle identifier to scope it
    /// by — which is not a state a running app is in, and is a reason to cache nothing rather than
    /// to guess at a directory.
    public static func live(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> TimelineSnapshotStore? {
        guard let bundleIdentifier,
            let caches = try? FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        else { return nil }
        return TimelineSnapshotStore(
            root: caches.appending(path: bundleIdentifier).appending(path: "timeline")
        )
    }

    /// The directory every snapshot on this device is under — the thing a sign-out empties, and
    /// the path a test asserts is gone.
    public var directory: URL { root }

    /// What was last written for this identity, or nil when there is nothing to render.
    ///
    /// Five different absences read as one, deliberately: no file at all (a first launch, or a
    /// system purge between two launches), bytes that will not decode, an envelope from a version
    /// this build does not recognise, a file belonging to somebody else, and a file that is a
    /// picture of some list other than the plain timeline. Each of them means "start empty and let
    /// the server say" — never an error screen, and never a crash.
    public func read(identity: TimelineSnapshotIdentity) -> TimelineSnapshot? {
        guard let data = try? Data(contentsOf: root.appending(path: identity.fileName)) else {
            return nil
        }
        guard let snapshot = try? JSONDecoder().decode(TimelineSnapshot.self, from: data) else {
            MemosLog.api.info("a timeline snapshot would not decode and was not read")
            return nil
        }
        guard snapshot.formatVersion == TimelineSnapshot.currentFormatVersion else {
            MemosLog.api.info("a timeline snapshot was written by another version and was not read")
            return nil
        }
        // The file name is a digest of this very pair, so a mismatch here is a collision or a
        // hand-moved file rather than the ordinary case — and it is still the identity in the
        // envelope, not the one in the path, that decides whose memos these are.
        guard snapshot.identity == identity else {
            MemosLog.api.info("a timeline snapshot belonging to another identity was not read")
            return nil
        }
        guard snapshot.query.isEmpty else {
            MemosLog.api.info("a timeline snapshot of a filtered list was not read")
            return nil
        }
        return snapshot
    }

    /// Writes the newest `capacity` memos as this identity's snapshot.
    ///
    /// Best effort by design, and silent by design: a picture that could not be taken costs the
    /// next launch its head start and must never cost the reader an error notice about a file.
    public func write(
        _ memos: [Memo],
        for identity: TimelineSnapshotIdentity,
        revision: Int,
        query: MemoQuery
    ) {
        // The rule is enforced where the picture is taken as well as where it is read: nothing but
        // the plain timeline is ever written down.
        guard query.isEmpty else { return }
        let snapshot = TimelineSnapshot(
            identity: identity,
            query: query,
            revision: revision,
            writtenAt: Date(),
            memos: Array(memos.prefix(Self.capacity))
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try writeData(data, root.appending(path: identity.fileName))
        } catch {
            MemosLog.api.info("a timeline snapshot was not written")
        }
    }

    public func remove(identity: TimelineSnapshotIdentity) {
        try? FileManager.default.removeItem(at: root.appending(path: identity.fileName))
    }

    /// Everything, whoever wrote it. This is what a credential going away means: a cache that
    /// outlives the token it was read with is somebody's memos left on a device nobody is signed
    /// in to.
    public func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The bytes on disk, replaced whole.
    ///
    /// Atomic because a half-written snapshot is a corrupt one, and the previous file is a better
    /// answer than a truncated one.
    public static let atomically: @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }
}

/// The one place snapshots are written and removed, and the two fences it applies to every write.
///
/// **Revision.** Each write carries the revision of the list it is a picture of, and this actor
/// keeps the newest revision it has committed for each identity. A write whose revision is not
/// higher is dropped. That is what makes the file the NEWEST picture rather than the last one to
/// arrive: an actor is not a queue (SE-0306), so two writes issued in order may reach it in either
/// order, and ordering must not be inferred from arrival.
///
/// **Session.** A write also carries the session generation it was ISSUED under, and this actor
/// reads the CURRENT one — synchronously, from a lock rather than another actor, with nothing
/// awaited in between — at the moment it is about to write. A write stamped with a session that has
/// since ended is refused there. That is the fence a serial queue cannot give: "the credential was
/// wiped, and then a write from the session that was wiped landed" is a perfectly ordered sequence,
/// and it leaves somebody's memos on a device nobody is signed in to.
public actor TimelineSnapshotWriter {
    private let store: TimelineSnapshotStore
    private let epoch: SessionEpoch
    /// The newest revision written by the CURRENT producer of each identity. Empty at launch, and
    /// emptied again whenever an identity changes hands, which is why a new producer's first
    /// picture always lands however far the last one had counted.
    private var committed: [TimelineSnapshotIdentity: Int] = [:]
    /// Who is entitled to write for each identity — the newest store that bound to it.
    private var producers: [TimelineSnapshotIdentity: Int] = [:]

    public init(store: TimelineSnapshotStore, epoch: SessionEpoch) {
        self.store = store
        self.epoch = epoch
    }

    /// The writer over the app's own container, or nil when there is nowhere to keep a snapshot.
    public static func live(epoch: SessionEpoch) -> TimelineSnapshotWriter? {
        TimelineSnapshotStore.live().map { TimelineSnapshotWriter(store: $0, epoch: epoch) }
    }

    public func read(identity: TimelineSnapshotIdentity) -> TimelineSnapshot? {
        store.read(identity: identity)
    }

    /// Claims an identity for one store, and RETIRES whoever held it before.
    ///
    /// Revisions order the pictures ONE store takes; they say nothing across two. A main-timeline
    /// store can be replaced inside a single session generation — a refused sign-in puts the state
    /// back without ending the session — and a store going out of scope does not recall the writes
    /// it has already submitted. So the predecessor's queued picture, however high its revision,
    /// would otherwise be the last word about a list it no longer holds. The token is what refuses
    /// it: one producer per identity, and the newest binding wins.
    ///
    /// Binding also forgets the revisions the retired producer had reached, so the newcomer's first
    /// picture lands whatever number it starts from.
    public func bind(to identity: TimelineSnapshotIdentity) -> Int {
        let token = producers[identity, default: 0] + 1
        producers[identity] = token
        committed[identity] = nil
        return token
    }

    /// - Parameters:
    ///   - producer: the token the writing store was given when it bound to this identity.
    ///   - revision: which version of the loaded list this is a picture of.
    ///   - session: the session generation the change this picture is of was issued under.
    public func write(
        _ memos: [Memo],
        for identity: TimelineSnapshotIdentity,
        producer: Int,
        revision: Int,
        query: MemoQuery,
        session: Int
    ) {
        guard session == epoch.current else {
            MemosLog.api.info("a timeline snapshot of a session that has ended was not written")
            return
        }
        guard producer == producers[identity] else {
            MemosLog.api.info("a timeline snapshot from a retired producer was not written")
            return
        }
        guard revision > committed[identity, default: Int.min] else {
            MemosLog.api.info("a timeline snapshot older than the one on disk was not written")
            return
        }
        store.write(memos, for: identity, revision: revision, query: query)
        committed[identity] = revision
    }

    /// Everything, whoever wrote it — and the memory of who was writing it, so the next session
    /// starts from nothing rather than from a producer or a revision it never issued.
    public func removeAll() {
        committed.removeAll()
        producers.removeAll()
        store.removeAll()
    }
}
