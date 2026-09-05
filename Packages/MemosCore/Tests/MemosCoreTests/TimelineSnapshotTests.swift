import Foundation
import MemosAPI
@testable import MemosCore
import Testing

/// The timeline that is on screen before the network answers.
///
/// Every case here drives the REAL `TimelineStore` — and, where a credential is involved, the REAL
/// `SessionStore` — over the REAL generated client with a scripted transport, and asserts on the
/// store's published `memos` or on the bytes that actually reached the disk. Nothing substitutes a
/// store: a stand-in would prove only that the test agrees with itself, and what is under test is
/// precisely which of the store's own paths write a file.
///
/// `@testable` for one thing only — `TimelineSnapshotIdentity.fileName`, so a case can corrupt,
/// delete or count the exact file the store uses rather than guess at a directory listing.
@MainActor
@Suite("Timeline snapshot")
struct TimelineSnapshotTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "timeline-snapshots")
            .appending(path: UUID().uuidString)
    }

    private let identity = TimelineSnapshotIdentity(server: Stub.baseURL, subject: "fabian")
    /// The session both sides of the fence read. One per test — Swift Testing builds a fresh suite
    /// value for each case — so a case that moves it moves nothing for anybody else.
    private let epoch = SessionEpoch()

    private func writer(
        root: URL,
        writeData: (@Sendable (Data, URL) throws -> Void)? = nil
    ) -> TimelineSnapshotWriter {
        TimelineSnapshotWriter(
            store: writeData.map { TimelineSnapshotStore(root: root, writeData: $0) }
                ?? TimelineSnapshotStore(root: root),
            epoch: epoch
        )
    }

    /// What is on the disk right now, read straight rather than through the store under test.
    private func onDisk(_ root: URL) -> TimelineSnapshot? {
        TimelineSnapshotStore(root: root).read(identity: identity)
    }

    private func exists(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: identity.fileName).path)
    }

    /// A session over an empty keychain, sharing `writer` with the timeline. Its transport answers
    /// whoami and is asked nothing else.
    private func sessionStore(writer: TimelineSnapshotWriter) -> SessionStore {
        SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            snapshots: writer,
            sessionEpoch: epoch
        )
    }

    private func page(_ uids: [String]) -> any APIProtocol {
        Stub.client { _, _, _ in Stub.json(Stub.memoList(uids, nextCursor: nil)) }
    }

    /// A store shaped exactly like the app's timeline: the default query, a snapshot writer and an
    /// identity to file it under.
    private func store(
        writer: TimelineSnapshotWriter,
        identity: TimelineSnapshotIdentity? = nil,
        query: MemoQuery = .empty,
        persists: Bool = true
    ) -> TimelineStore {
        TimelineStore(
            query: query,
            snapshots: writer,
            snapshotIdentity: identity ?? self.identity,
            sessionEpoch: epoch,
            persists: persists
        )
    }

    /// A memo value, for the cases that write an envelope by hand instead of loading one.
    private func memoValue(_ uid: String) -> Memo {
        Memo(
            uid: uid,
            owner: "fabian",
            mine: true,
            content: "hello",
            visibility: .private,
            pinned: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    // MARK: - round trip

    @Test("memos written by one run are read back whole by the next")
    func roundTripSurvivesAFreshStore() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let written = store(writer: writer(root: root))
        let client = Stub.client { _, _, _ in
            Stub.json(
                Stub.page([
                    Stub.memo(
                        uid: "a",
                        content: "with a picture",
                        attachments: [Stub.attachment(uid: "att-1", status: "ready")]
                    ),
                    Stub.memo(uid: "b", content: "and one without"),
                ])
            )
        }

        await written.refresh(using: client, baseURL: Stub.baseURL)
        #expect(written.memos.count == 2, "control: the list this case is a picture of")

        // A second store over the same directory IS the next launch: nothing is carried over in
        // memory, so anything that comes back came off the disk.
        let relaunched = store(writer: writer(root: root))
        await relaunched.restoreSnapshot()

        #expect(relaunched.memos == written.memos)
        #expect(relaunched.memos.first?.attachments.map(\.uid) == ["att-1"])
        #expect(relaunched.memos.first?.createdAt == written.memos.first?.createdAt)
        // Never a source of pagination cursors: the snapshot says nothing about what the server
        // would answer next, and a restored list must not claim to know.
        #expect(relaunched.hasMore, "a restored list must ask the server rather than end there")
    }

    // MARK: - identity

    @Test("a snapshot is rendered for the identity that wrote it and for no other")
    func identityScoping() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store(writer: writer(root: root))
            .refresh(using: page(["a", "b"]), baseURL: Stub.baseURL)

        let otherSubject = store(
            writer: writer(root: root),
            identity: TimelineSnapshotIdentity(server: Stub.baseURL, subject: "somebody-else")
        )
        await otherSubject.restoreSnapshot()
        #expect(otherSubject.memos.isEmpty, "another subject's timeline was rendered")

        let otherServer = store(
            writer: writer(root: root),
            identity: TimelineSnapshotIdentity(
                server: URL(string: "https://other.example.invalid")!,
                subject: "fabian"
            )
        )
        await otherServer.restoreSnapshot()
        #expect(otherServer.memos.isEmpty, "the same subject on another server was rendered")

        let matching = store(writer: writer(root: root))
        await matching.restoreSnapshot()
        #expect(
            matching.memos.map(\.uid) == ["a", "b"],
            "control: the identity that wrote the snapshot does render it"
        )
    }

    @Test("an envelope in this identity's file but stamped with another's is not read")
    func anEnvelopeStampedWithAnotherIdentityIsNotRead() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // The file NAME is a digest of the identity, so ordinarily another account's snapshot is
        // another file. This is the case where that is not enough — a copied container, a digest
        // collision, a file moved by hand — and the answer must come from what the envelope says
        // it is, not from where it was found.
        try write(
            stamped: TimelineSnapshotIdentity(server: Stub.baseURL, subject: "somebody-else"),
            to: root
        )
        let timeline = store(writer: writer(root: root))
        await timeline.restoreSnapshot()
        #expect(timeline.memos.isEmpty, "an envelope belonging to somebody else was rendered")

        try write(to: root)
        let control = store(writer: writer(root: root))
        await control.restoreSnapshot()
        #expect(control.memos.map(\.uid) == ["a"], "control: this identity's envelope is read")
    }

    @Test("a snapshot on screen goes when the session becomes somebody else's")
    func aRenderedSnapshotIsDiscardedWhenTheIdentityChanges() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store(writer: writer(root: root)).refresh(using: page(["a"]), baseURL: Stub.baseURL)
        let timeline = store(writer: writer(root: root))
        await timeline.restoreSnapshot()
        #expect(timeline.memos.map(\.uid) == ["a"], "control: the snapshot did render")

        timeline.sessionIdentityChanged(
            to: TimelineSnapshotIdentity(server: Stub.baseURL, subject: "somebody-else")
        )
        #expect(timeline.memos.isEmpty)

        // And nothing more is written under an identity this store has been told it no longer has.
        await timeline.refresh(using: page(["b"]), baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.map(\.uid) == ["a"])
    }

    @Test("rows the server sent for one identity are not left on screen for another")
    func serverLoadedRowsAreDiscardedWhenTheIdentityChanges() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timeline = store(writer: writer(root: root))
        // Nothing restored: these rows came off the wire, which is exactly the case a switch
        // between two signed-in identities on one server produces — the screen holding this store
        // is never torn down, so nothing else empties it.
        await timeline.refresh(using: page(["a", "b"]), baseURL: Stub.baseURL)
        #expect(timeline.memos.map(\.uid) == ["a", "b"], "control: the server's rows are up")

        timeline.sessionIdentityChanged(
            to: TimelineSnapshotIdentity(server: Stub.baseURL, subject: "somebody-else")
        )

        #expect(timeline.memos.isEmpty, "one account's memos were left on screen for another")
        #expect(!timeline.hasNewer)
        // And the withdrawn identity's snapshot is not put back in their place either.
        await timeline.restoreSnapshot()
        #expect(timeline.memos.isEmpty, "the outgoing identity's snapshot was rendered")
    }

    @Test("the same identity again changes nothing")
    func theSameIdentityLeavesTheSnapshotAlone() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store(writer: writer(root: root)).refresh(using: page(["a"]), baseURL: Stub.baseURL)
        let timeline = store(writer: writer(root: root))
        await timeline.restoreSnapshot()

        timeline.sessionIdentityChanged(to: identity)

        #expect(timeline.memos.map(\.uid) == ["a"])
        await timeline.refresh(using: page(["b"]), baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.map(\.uid) == ["b"], "control: this store still writes")
    }

    // MARK: - the credential going away

    @Test("signing out removes the snapshot and the next launch is empty")
    func signOutRemovesTheSnapshot() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = writer(root: root)
        await store(writer: writer).refresh(using: page(["a"]), baseURL: Stub.baseURL)
        #expect(exists(root), "control: a snapshot was written")

        await sessionStore(writer: writer).signOutWithoutRevoking()

        #expect(!exists(root))
        let relaunched = store(writer: writer)
        await relaunched.restoreSnapshot()
        #expect(relaunched.memos.isEmpty)
    }

    @Test("a 401 takes the snapshot with the credential")
    func unauthorizedRemovesTheSnapshot() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = writer(root: root)
        await store(writer: writer).refresh(using: page(["a"]), baseURL: Stub.baseURL)
        #expect(exists(root), "control: a snapshot was written")

        await sessionStore(writer: writer).handle(.unauthorized)

        #expect(!exists(root))
    }

    @Test("a launch that finds no credential leaves no snapshot behind either")
    func restoreWithoutACredentialWipes() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = writer(root: root)
        await store(writer: writer).refresh(using: page(["a"]), baseURL: Stub.baseURL)
        #expect(exists(root), "control: a snapshot was written")

        await sessionStore(writer: writer).restore()

        #expect(!exists(root))
    }

    @Test("signing in leaves the outgoing account's timeline nowhere on the device")
    func signInRemovesTheOutgoingSnapshot() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = writer(root: root)
        await store(writer: writer).refresh(using: page(["a"]), baseURL: Stub.baseURL)
        #expect(exists(root), "control: a snapshot was written")

        let session = sessionStore(writer: writer)
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")

        #expect(session.state.user?.subject == "fabian", "control: the sign-in did happen")
        #expect(!exists(root))
    }

    @Test("a snapshot still on its way to the disk cannot land behind a sign-out")
    func aWriteCannotOvertakeTheWipe() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let shared = writer(root: root) { data, url in
            entered.set(true)
            // Slow, not held: the point is that a removal issued while this is in the air still
            // runs after it — not that anything can be blocked open for ever.
            Thread.sleep(forTimeInterval: 0.05)
            try data.write(to: url, options: .atomic)
        }
        let timeline = store(writer: shared)
        await timeline.refresh(using: page(["a"]), baseURL: Stub.baseURL)
        #expect(exists(root), "control: the directory was not empty before the sign-out")

        entered.set(false)
        let inFlight = Task { await timeline.refresh(using: page(["b"]), baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        await sessionStore(writer: shared).signOutWithoutRevoking()
        await inFlight.value

        #expect(!exists(root), "a write in the air landed behind the sign-out")
        #expect(onDisk(root) == nil)
    }

    // MARK: - the lineage fence

    @Test("a page that answers for a superseded list reaches neither memory nor disk")
    func aSupersededPageIsNotWritten() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let firstPages = Counter()
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            if path.contains("cursor=page-2") {
                entered.set(true)
                while !release.get() {
                    try await Task.sleep(for: .milliseconds(1))
                }
                return Stub.json(Stub.memoList(["stale"], nextCursor: nil))
            }
            firstPages.increment()
            return firstPages.count == 1
                ? Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
                : Stub.json(Stub.memoList(["fresh-a"], nextCursor: nil))
        }
        let timeline = TimelineStore(
            pageSize: 1,
            snapshots: writer(root: root),
            snapshotIdentity: identity,
            sessionEpoch: epoch,
            persists: true
        )

        await timeline.refresh(using: client, baseURL: Stub.baseURL)
        let inFlight = Task { await timeline.loadMore(using: client, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        // The list the held page was a continuation of is gone before it lands.
        await timeline.refresh(using: client, baseURL: Stub.baseURL)
        release.set(true)
        await inFlight.value

        #expect(timeline.memos.map(\.uid) == ["fresh-a"], "the superseded page was merged anyway")
        #expect(onDisk(root)?.memos.map(\.uid) == ["fresh-a"], "a superseded page was written")
    }

    // MARK: - which lists are kept at all

    @Test("only the plain timeline is written down")
    func onlyTheDefaultQueryIsWritten() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = writer(root: root)
        let anchored = store(
            writer: shared,
            query: MemoQuery(anchor: .day(year: 2026, month: 8, day: 23))
        )
        let tagged = store(writer: shared, query: MemoQuery(tags: ["holiday"]))
        let searched = store(writer: shared, query: MemoQuery(term: "beach"))

        await anchored.refresh(using: page(["anchored"]), baseURL: Stub.baseURL)
        await tagged.refresh(using: page(["tagged"]), baseURL: Stub.baseURL)
        await searched.refresh(using: page(["searched"]), baseURL: Stub.baseURL)

        #expect(anchored.memos.map(\.uid) == ["anchored"], "control: the filtered lists did load")
        #expect(!exists(root), "a list nobody will ask for again was written down")

        await store(writer: shared).refresh(using: page(["plain"]), baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.map(\.uid) == ["plain"], "control: the plain timeline is kept")
    }

    @Test("an envelope that is a picture of a filtered list is not read")
    func aFilteredEnvelopeReadsAsAbsent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write(query: MemoQuery(tags: ["holiday"]), to: root)
        let filtered = store(writer: writer(root: root))
        await filtered.restoreSnapshot()
        #expect(filtered.memos.isEmpty)

        try write(query: .empty, to: root)
        let plain = store(writer: writer(root: root))
        await plain.restoreSnapshot()
        #expect(plain.memos.map(\.uid) == ["a"], "control: a plain envelope is read")
    }

    // MARK: - reading what is on the disk

    @Test("a timeline that cannot be reached still shows what the phone last saw")
    func renderFromSnapshotWithAFailingTransport() async {
        struct Offline: Error {}
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store(writer: writer(root: root))
            .refresh(using: page(["a", "b"]), baseURL: Stub.baseURL)

        let relaunched = store(writer: writer(root: root))
        await relaunched.restoreSnapshot()
        #expect(relaunched.memos.map(\.uid) == ["a", "b"])

        let offline = Stub.client { _, _, _ in throw Offline() }
        await relaunched.refresh(using: offline, baseURL: Stub.baseURL)

        #expect(
            relaunched.memos.map(\.uid) == ["a", "b"],
            "a server that would not answer emptied the list it could not replace"
        )
        // And the picture survives the failure: the next launch must not be worse off for having
        // tried. (Whether the failure also raises a notice is decision 7's, not this phase's.)
        #expect(onDisk(root)?.memos.map(\.uid) == ["a", "b"])
    }

    @Test("garbage bytes read as an empty timeline, never as a crash")
    func corruptBytesReadAsAbsent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store(writer: writer(root: root)).refresh(using: page(["a"]), baseURL: Stub.baseURL)
        let control = store(writer: writer(root: root))
        await control.restoreSnapshot()
        #expect(control.memos.map(\.uid) == ["a"], "control: this file rendered before it was cut")

        // Real bytes, truncated mid-envelope — what a write interrupted by a crash leaves, and
        // what nothing is allowed to throw on.
        let file = root.appending(path: identity.fileName)
        let whole = try Data(contentsOf: file)
        try whole.prefix(whole.count / 2).write(to: file)

        let corrupted = store(writer: writer(root: root))
        await corrupted.restoreSnapshot()
        #expect(corrupted.memos.isEmpty)
    }

    @Test("an envelope from another format version is not read")
    func aFutureFormatVersionReadsAsAbsent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write(formatVersion: TimelineSnapshot.currentFormatVersion + 1, to: root)
        let future = store(writer: writer(root: root))
        await future.restoreSnapshot()
        #expect(future.memos.isEmpty)

        // The same envelope, one number different: without this the case would pass against a
        // reader that renders nothing at all.
        try write(formatVersion: TimelineSnapshot.currentFormatVersion, to: root)
        let current = store(writer: writer(root: root))
        await current.restoreSnapshot()
        #expect(current.memos.map(\.uid) == ["a"], "control: the current version does render")
    }

    @Test("a snapshot directory the system purged is a cold start")
    func aPurgedDirectoryIsAColdStart() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store(writer: writer(root: root)).refresh(using: page(["a"]), baseURL: Stub.baseURL)
        try? FileManager.default.removeItem(at: root)

        let relaunched = store(writer: writer(root: root))
        await relaunched.restoreSnapshot()

        #expect(relaunched.memos.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - what a snapshot holds

    @Test("a snapshot holds the newest 200 memos, however many are loaded")
    func theSnapshotIsCapped() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let uids = (0..<300).map { "memo-\($0)" }
        let timeline = store(writer: writer(root: root))

        await timeline.refresh(using: page(uids), baseURL: Stub.baseURL)

        #expect(timeline.memos.count == 300, "control: the loaded list itself is not capped")
        #expect(onDisk(root)?.memos.count == TimelineSnapshotStore.capacity)
        let kept = Array(uids.prefix(TimelineSnapshotStore.capacity))
        #expect(onDisk(root)?.memos.map(\.uid) == kept)
    }

    @Test("a successful load replaces the snapshot rather than merging into it")
    func aLoadReplacesTheSnapshot() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timeline = store(writer: writer(root: root))

        await timeline.refresh(using: page(["a", "b"]), baseURL: Stub.baseURL)
        await timeline.refresh(using: page(["c"]), baseURL: Stub.baseURL)

        #expect(onDisk(root)?.memos.map(\.uid) == ["c"])
    }

    @Test("a write that throws leaves the previous snapshot where it was")
    func aFailedWriteKeepsThePreviousSnapshot() async {
        struct DiskFull: Error {}
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store(writer: writer(root: root)).refresh(using: page(["a"]), baseURL: Stub.baseURL)

        let refusing = store(writer: writer(root: root) { _, _ in throw DiskFull() })
        await refusing.refresh(using: page(["b"]), baseURL: Stub.baseURL)

        #expect(refusing.memos.map(\.uid) == ["b"], "the failed write took the screen with it")
        #expect(onDisk(root)?.memos.map(\.uid) == ["a"], "the previous snapshot was destroyed")
    }

    @Test("a store with no identity to file one under keeps no snapshot")
    func noIdentityIsNoSnapshot() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let anonymous = TimelineStore(
            snapshots: writer(root: root),
            sessionEpoch: epoch,
            persists: true
        )

        await anonymous.refresh(using: page(["a"]), baseURL: Stub.baseURL)
        await anonymous.restoreSnapshot()

        #expect(anonymous.memos.map(\.uid) == ["a"], "control: the list itself loaded")
        #expect(
            !FileManager.default.fileExists(atPath: root.path),
            "a list with no identity to file it under wrote a file anyway"
        )
    }

    // MARK: - the session fence

    @Test("a page issued in one session and answered in the next reaches neither list nor disk")
    func aPageFromAnEndedSessionIsDropped() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in
            entered.set(true)
            while !release.get() {
                try await Task.sleep(for: .milliseconds(1))
            }
            return Stub.json(Stub.memoList(["late"], nextCursor: nil))
        }
        let timeline = store(writer: writer(root: root))

        let inFlight = Task { await timeline.refresh(using: client, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        // The device becomes somebody else's — or nobody's — while the page is in the air.
        epoch.adopt(1)
        release.set(true)
        await inFlight.value

        #expect(timeline.memos.isEmpty, "a page from a session that ended reached the list")
        #expect(onDisk(root) == nil, "a page from a session that ended reached the disk")
    }

    @Test("the same page under the session that issued it reaches both")
    func aPageFromTheCurrentSessionIsApplied() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in
            entered.set(true)
            while !release.get() {
                try await Task.sleep(for: .milliseconds(1))
            }
            return Stub.json(Stub.memoList(["late"], nextCursor: nil))
        }
        let timeline = store(writer: writer(root: root))

        let inFlight = Task { await timeline.refresh(using: client, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        release.set(true)
        await inFlight.value

        #expect(timeline.memos.map(\.uid) == ["late"], "control: the list took the page")
        #expect(onDisk(root)?.memos.map(\.uid) == ["late"], "control: the disk took the page")
    }

    @Test("a write from a session that has ended is refused at the moment of writing")
    func theWriterRefusesAnEndedSession() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = writer(root: root)
        let producer = await shared.bind(to: identity)

        await shared.write(
            [memoValue("mine")],
            for: identity,
            producer: producer,
            revision: 1,
            query: .empty,
            session: epoch.current
        )
        #expect(onDisk(root)?.memos.map(\.uid) == ["mine"], "control: this session does write")

        // The device becomes somebody else's between the page being issued and its picture being
        // written.
        epoch.adopt(1)
        await shared.write(
            [memoValue("theirs")],
            for: identity,
            producer: producer,
            revision: 2,
            query: .empty,
            session: 0
        )

        #expect(onDisk(root)?.memos.map(\.uid) == ["mine"], "a write from an older session landed")
    }

    @Test("a write issued before the credential went cannot land after it")
    func aQueuedWriteCannotLandAfterAWipe() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = writer(root: root)
        let producer = await shared.bind(to: identity)
        await shared.write(
            [memoValue("a")],
            for: identity,
            producer: producer,
            revision: 1,
            query: .empty,
            session: 0
        )
        #expect(exists(root), "control: the directory was not empty before the wipe")

        // What a sign-out is, in the order a sign-out does it.
        epoch.adopt(1)
        await shared.removeAll()
        await shared.write(
            [memoValue("b")],
            for: identity,
            producer: producer,
            revision: 2,
            query: .empty,
            session: 0
        )

        #expect(!exists(root), "an obsolete write recreated the file after the wipe")
    }

    @Test("a picture of an older list never replaces a newer one, whatever order they arrive in")
    func anOlderRevisionNeverWins() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = writer(root: root)
        let producer = await shared.bind(to: identity)

        await shared.write(
            [memoValue("newer")],
            for: identity,
            producer: producer,
            revision: 6,
            query: .empty,
            session: 0
        )
        // The picture of revision 5 reaches the writer SECOND. An actor is not a queue, so this is
        // a sequence the app really can produce; arriving later must not make it the newer word.
        await shared.write(
            [memoValue("older")],
            for: identity,
            producer: producer,
            revision: 5,
            query: .empty,
            session: 0
        )

        #expect(onDisk(root)?.memos.map(\.uid) == ["newer"], "a stale revision overwrote a newer")
        #expect(onDisk(root)?.revision == 6)
    }

    // MARK: - the snapshot follows the list

    @Test("what is loaded is what is kept, and a delete is kept too")
    func theSnapshotFollowsTheList() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let uids = (0..<100).map { "memo-\($0)" }
        let timeline = store(writer: writer(root: root))
        let client = Stub.client { _, _, operation in
            operation.contains("delete_memo")
                ? Stub.empty(.noContent)
                : Stub.json(Stub.memoList(uids, nextCursor: nil))
        }

        await timeline.refresh(using: client, baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.count == 100, "the loaded list is not what was kept")

        let deleted = await timeline.delete(uid: "memo-7", using: client)

        #expect(deleted, "control: the server confirmed the delete")
        let relaunched = store(writer: writer(root: root))
        await relaunched.restoreSnapshot()
        #expect(relaunched.memos.count == 99)
        #expect(!relaunched.memos.contains { $0.uid == "memo-7" }, "a deleted memo came back")
    }

    // MARK: - provenance

    @Test("rows still on screen from an anchored day are never written down as the timeline")
    func retainedAnchoredRowsAreNotPersisted() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timeline = store(
            writer: writer(root: root),
            query: MemoQuery(anchor: .day(year: 2026, month: 8, day: 23))
        )
        let client = Stub.client { _, _, operation in
            operation.contains("delete_memo")
                ? Stub.empty(.noContent)
                : Stub.json(Stub.memoList(["anchored"], nextCursor: nil))
        }
        await timeline.refresh(using: client, baseURL: Stub.baseURL)
        #expect(timeline.memos.map(\.uid) == ["anchored"], "control: the anchored list loaded")
        #expect(!exists(root), "control: an anchored list is not written down")

        // The anchor is cleared — but the rows are the anchored day's until a refresh replaces
        // them, and a confirmed change to them is still a change to THAT list.
        timeline.setQuery(.empty)
        let deleted = await timeline.delete(uid: "anchored", using: client)

        #expect(deleted, "control: the server confirmed the delete")
        #expect(!exists(root), "rows admitted under an anchor were written as the timeline")

        // And a load that really does replace them with the plain timeline is written.
        await timeline.refresh(using: page(["plain"]), baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.map(\.uid) == ["plain"], "control: the plain list is kept")
    }

    @Test("a store its owner says is not the timeline never writes")
    func aStoreThatDoesNotPersistNeverWrites() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = writer(root: root)
        let results = store(writer: shared, persists: false)

        await results.refresh(using: page(["a"]), baseURL: Stub.baseURL)

        #expect(results.memos.map(\.uid) == ["a"], "control: the list itself loaded")
        #expect(
            !FileManager.default.fileExists(atPath: root.path),
            "a list that is not the timeline wrote the timeline's file"
        )
        // It did not even claim the identity: the first store that does gets the first token.
        let claimed = await shared.bind(to: identity)
        #expect(claimed == 1, "a list that is not the timeline claimed the timeline's identity")
    }

    // MARK: - quiescence

    @Test("nothing is written down while an optimistic tick is outstanding")
    func anOutstandingTickHoldsTheWriteBack() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            guard operation.contains("patch_memo") else {
                return Stub.json(
                    Stub.page([
                        Stub.memo(uid: "a", content: "- [ ] task"),
                        Stub.memo(uid: "b", content: "b"),
                    ])
                )
            }
            entered.set(true)
            while !release.get() {
                try await Task.sleep(for: .milliseconds(1))
            }
            return Stub.empty(.internalServerError)
        }
        let timeline = store(writer: writer(root: root))
        await timeline.refresh(using: client, baseURL: Stub.baseURL)
        #expect(
            onDisk(root)?.memos.map(\.content) == ["- [ ] task", "b"],
            "control: the loaded list was written down"
        )

        let ticking = Task {
            await timeline.toggleTask(at: 0, in: "a", using: client, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        var changed = timeline.memos[1]
        changed.content = "changed"
        await timeline.apply(changed)

        #expect(timeline.memos[1].content == "changed", "control: the change reached the list")
        #expect(
            onDisk(root)?.memos.map(\.content) == ["- [ ] task", "b"],
            "a change was written down while an unconfirmed tick was on screen"
        )

        release.set(true)
        let ticked = await ticking.value

        #expect(!ticked, "control: the server refused the tick")
        #expect(
            onDisk(root)?.memos.map(\.content) == ["- [ ] task", "changed"],
            "the settle did not write the list the tick was holding back"
        )
    }

    @Test("a second tick on a memo whose first one is still out is refused")
    func aSecondToggleOnTheSameMemoIsRefused() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let patches = Counter()
        let client = Stub.client { _, _, operation in
            guard operation.contains("patch_memo") else {
                return Stub.json(Stub.page([Stub.memo(uid: "a", content: "- [ ] task")]))
            }
            patches.increment()
            entered.set(true)
            while !release.get() {
                try await Task.sleep(for: .milliseconds(1))
            }
            return Stub.empty(.conflict)
        }
        let timeline = store(writer: writer(root: root))
        await timeline.refresh(using: client, baseURL: Stub.baseURL)

        let first = Task {
            await timeline.toggleTask(at: 0, in: "a", using: client, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        let second = await timeline.toggleTask(
            at: 0, in: "a", using: client, baseURL: Stub.baseURL
        )
        release.set(true)
        let firstAnswer = await first.value

        #expect(!second, "the second tick was taken while the first was still out")
        #expect(patches.count == 1, "two ticks on one memo put two requests on the wire")
        #expect(!firstAnswer, "control: the server refused the tick it did receive")
        #expect(timeline.memos.map(\.content) == ["- [ ] task"], "the rollback lost the value")
        #expect(
            onDisk(root)?.memos.map(\.content) == ["- [ ] task"],
            "an unconfirmed tick reached the disk"
        )
    }

    // MARK: - the watermark

    @Test("a store built for an identity that has been written before goes on writing")
    func aFreshStoreForTheSameIdentityKeepsWriting() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = writer(root: root)

        await store(writer: shared).refresh(using: page(["a"]), baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.map(\.uid) == ["a"], "control: the first store wrote")

        // The screen is torn down and made again — a second store, the same identity, numbering
        // its own changes from scratch.
        await store(writer: shared).refresh(using: page(["b"]), baseURL: Stub.baseURL)

        #expect(onDisk(root)?.memos.map(\.uid) == ["b"], "the rebuilt screen cannot write")
    }

    @Test("a wipe forgets who was writing and how far they had got")
    func aWipeResetsTheProducerSequence() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = writer(root: root)
        let first = await shared.bind(to: identity)
        await shared.write(
            [memoValue("old")],
            for: identity,
            producer: first,
            revision: 3,
            query: .empty,
            session: 0
        )
        #expect(exists(root), "control: the first producer wrote")

        await shared.removeAll()
        let second = await shared.bind(to: identity)
        #expect(second == 1, "the wipe did not reset the producer sequence")
        await shared.write(
            [memoValue("new")],
            for: identity,
            producer: second,
            revision: 1,
            query: .empty,
            session: 0
        )

        #expect(onDisk(root)?.memos.map(\.uid) == ["new"], "the wipe did not reset the numbering")
    }

    @Test("a store that has been replaced cannot write again, however high it had counted")
    func aRetiredProducerCannotLand() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = writer(root: root)
        // The predecessor takes a picture of revision 44 and hands it over — and only then is it
        // replaced. Its write is still in the air.
        let predecessor = await shared.bind(to: identity)
        let successor = await shared.bind(to: identity)

        await shared.write(
            [memoValue("successor")],
            for: identity,
            producer: successor,
            revision: 42,
            query: .empty,
            session: 0
        )
        await shared.write(
            [memoValue("predecessor")],
            for: identity,
            producer: predecessor,
            revision: 44,
            query: .empty,
            session: 0
        )

        #expect(
            onDisk(root)?.memos.map(\.uid) == ["successor"],
            "a replaced store's picture landed over the store that replaced it"
        )
        #expect(onDisk(root)?.revision == 42)
    }

    @Test("an anchor that has been asked for holds the write back until it is answered")
    func aRequestedAnchorHoldsTheWriteBack() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timeline = store(writer: writer(root: root))
        let client = Stub.client { _, _, operation in
            operation.contains("delete_memo")
                ? Stub.empty(.noContent)
                : Stub.json(Stub.memoList(["plain", "other"], nextCursor: nil))
        }
        await timeline.refresh(using: client, baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.count == 2, "control: the plain list was written")

        // A day has been chosen; its page has not come back. The rows are still the plain
        // timeline's, and the next thing this store does is replace them.
        timeline.setQuery(MemoQuery(anchor: .day(year: 2026, month: 8, day: 23)))
        let deleted = await timeline.delete(uid: "other", using: client)

        #expect(deleted, "control: the server confirmed the delete")
        #expect(onDisk(root)?.memos.count == 2, "a list under a requested anchor was written")
    }

    // MARK: - hand-built envelopes

    private func write(
        formatVersion: Int = TimelineSnapshot.currentFormatVersion,
        query: MemoQuery = .empty,
        stamped: TimelineSnapshotIdentity? = nil,
        to root: URL
    ) throws {
        let envelope = TimelineSnapshot(
            formatVersion: formatVersion,
            identity: stamped ?? identity,
            query: query,
            revision: 1,
            writtenAt: Date(timeIntervalSince1970: 2),
            memos: [memoValue("a")]
        )
        try JSONEncoder().encode(envelope).write(to: root.appending(path: identity.fileName))
    }
}
