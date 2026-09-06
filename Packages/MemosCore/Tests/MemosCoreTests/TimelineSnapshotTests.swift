import Foundation
import MemosAPI
@testable import MemosCore
import MemosOutbox
import Testing

// The transport is handed the contract's own operationId, not the generated Swift method name.
private let listMemosOperation = "list_memos_api_memos_get"
private let tokenRenewOperation = "native_renew_api_auth_native_renew_post"
private let tokenReadOperation = "native_token_api_auth_native_token_get"

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
    /// The authority a writer built WITHOUT a session is fenced by. One per test — Swift Testing
    /// builds a fresh suite value for each case — so a case that moves it moves nothing for
    /// anybody else. Where a case has a real `SessionStore`, the session's own epoch is the one
    /// that counts and this is not used.
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

    /// A session over an empty keychain, OWNING the writer the timeline writes through. Its
    /// transport answers whoami and is asked nothing else.
    ///
    /// It builds the writer exactly as the app does — from a directory — so the epoch the writer
    /// refuses by is this session's own and no case can hand it another.
    private func sessionStore(
        root: URL,
        writeData: (@Sendable (Data, URL) throws -> Void)? = nil,
        removeItem: (@Sendable (URL) throws -> Void)? = nil
    ) -> SessionStore {
        SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            snapshots: TimelineSnapshotStore(
                root: root,
                writeData: writeData ?? TimelineSnapshotStore.atomically,
                removeItem: removeItem ?? TimelineSnapshotStore.removingItem
            )
        )
    }

    /// A session whose transport a case scripts by operation, over the writer it owns.
    ///
    /// The cases below that use it are about what the SESSION does to a list and a file — a
    /// sign-out, a renewal — so nothing here is a stand-in: the real store signs in, the real
    /// timeline reads through the real writer, and the fences are the ones the app runs.
    private func signedInSession(
        root: URL,
        removeItem: (@Sendable (URL) throws -> Void)? = nil,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            snapshots: TimelineSnapshotStore(
                root: root,
                removeItem: removeItem ?? TimelineSnapshotStore.removingItem
            )
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

        await written.refresh(using: client.handle, baseURL: Stub.baseURL)
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
            .refresh(using: page(["a", "b"]).handle, baseURL: Stub.baseURL)

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
        await store(writer: writer(root: root))
            .refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        let timeline = store(writer: writer(root: root))
        await timeline.restoreSnapshot()
        #expect(timeline.memos.map(\.uid) == ["a"], "control: the snapshot did render")

        timeline.sessionIdentityChanged(
            to: TimelineSnapshotIdentity(server: Stub.baseURL, subject: "somebody-else")
        )
        #expect(timeline.memos.isEmpty)

        // And nothing more is written under an identity this store has been told it no longer has.
        await timeline.refresh(using: page(["b"]).handle, baseURL: Stub.baseURL)
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
        await timeline.refresh(using: page(["a", "b"]).handle, baseURL: Stub.baseURL)
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
        await store(writer: writer(root: root))
            .refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        let timeline = store(writer: writer(root: root))
        await timeline.restoreSnapshot()

        timeline.sessionIdentityChanged(to: identity)

        #expect(timeline.memos.map(\.uid) == ["a"])
        await timeline.refresh(using: page(["b"]).handle, baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.map(\.uid) == ["b"], "control: this store still writes")
    }

    // MARK: - the credential going away

    @Test("signing out removes the snapshot and the next launch is empty")
    func signOutRemovesTheSnapshot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = sessionStore(root: root)
        let writer = try #require(session.snapshots)
        await store(writer: writer).refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        #expect(exists(root), "control: a snapshot was written")

        await session.signOutWithoutRevoking()

        #expect(!exists(root))
        let relaunched = store(writer: writer)
        await relaunched.restoreSnapshot()
        #expect(relaunched.memos.isEmpty)
    }

    @Test("a 401 takes the snapshot with the credential")
    func unauthorizedRemovesTheSnapshot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = sessionStore(root: root)
        let writer = try #require(session.snapshots)
        await store(writer: writer).refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        #expect(exists(root), "control: a snapshot was written")

        await session.handle(.unauthorized)

        #expect(!exists(root))
    }

    @Test("a launch that finds no credential leaves no snapshot behind either")
    func restoreWithoutACredentialWipes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = sessionStore(root: root)
        let writer = try #require(session.snapshots)
        await store(writer: writer).refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        #expect(exists(root), "control: a snapshot was written")

        await session.restore()

        #expect(!exists(root))
    }

    /// The OTHER branch of `restore()` that reaches the wipe, and it reaches it on its own rather
    /// than through the identity-scoped list: the credential here is good and the session is about
    /// to be admitted on it, so the last-known identity must NOT be forgotten — only the timeline
    /// the interrupted switch left behind goes.
    @Test("a launch that finds a licence for another server takes that timeline with it")
    func restoreWithAMismatchedLicenceWipes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = InMemoryCredentials()
        try credentials.set("memos_pat_good", for: SessionStore.tokenAccount)
        try credentials.set(Stub.baseURL.absoluteString, for: SessionStore.serverAccount)
        let account = SpyAccountStore()
        account.publish(
            AccountBinding(
                serverBaseURL: URL(string: "https://other.example.invalid")!,
                ownerSubject: "somebody-else"
            )
        )
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            account: account,
            snapshots: TimelineSnapshotStore(root: root)
        )
        let timeline = store(writer: try #require(session.snapshots))
        await timeline.refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        #expect(exists(root), "control: a snapshot was written")

        await session.restore()

        #expect(session.state.user != nil, "control: the stored credential was admitted")
        #expect(!exists(root), "an interrupted switch left one account's timeline on the device")
    }

    @Test("signing in leaves the outgoing account's timeline nowhere on the device")
    func signInRemovesTheOutgoingSnapshot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = sessionStore(root: root)
        let writer = try #require(session.snapshots)
        await store(writer: writer).refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        #expect(exists(root), "control: a snapshot was written")

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")

        #expect(session.state.user?.subject == "fabian", "control: the sign-in did happen")
        #expect(!exists(root))
    }

    @Test("a snapshot still on its way to the disk cannot land behind a sign-out")
    func aWriteCannotOvertakeTheWipe() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let session = sessionStore(
            root: root,
            writeData: { data, url in
                entered.set(true)
                // Slow, not held: the point is that a removal issued while this is in the air
                // still runs after it — not that anything can be blocked open for ever.
                Thread.sleep(forTimeInterval: 0.05)
                try data.write(to: url, options: .atomic)
            }
        )
        let shared = try #require(session.snapshots)
        let timeline = store(writer: shared)
        await timeline.refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        #expect(exists(root), "control: the directory was not empty before the sign-out")

        entered.set(false)
        let inFlight = Task {
            await timeline.refresh(using: page(["b"]).handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        await session.signOutWithoutRevoking()
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
            persists: true
        )

        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
        let inFlight = Task { await timeline.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        // The list the held page was a continuation of is gone before it lands.
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
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

        await anchored.refresh(using: page(["anchored"]).handle, baseURL: Stub.baseURL)
        await tagged.refresh(using: page(["tagged"]).handle, baseURL: Stub.baseURL)
        await searched.refresh(using: page(["searched"]).handle, baseURL: Stub.baseURL)

        #expect(anchored.memos.map(\.uid) == ["anchored"], "control: the filtered lists did load")
        #expect(!exists(root), "a list nobody will ask for again was written down")

        await store(writer: shared).refresh(using: page(["plain"]).handle, baseURL: Stub.baseURL)
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
            .refresh(using: page(["a", "b"]).handle, baseURL: Stub.baseURL)

        let relaunched = store(writer: writer(root: root))
        await relaunched.restoreSnapshot()
        #expect(relaunched.memos.map(\.uid) == ["a", "b"])

        let offline = Stub.client { _, _, _ in throw Offline() }
        await relaunched.refresh(using: offline.handle, baseURL: Stub.baseURL)

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
        await store(writer: writer(root: root))
            .refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
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
        await store(writer: writer(root: root))
            .refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
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

        await timeline.refresh(using: page(uids).handle, baseURL: Stub.baseURL)

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

        await timeline.refresh(using: page(["a", "b"]).handle, baseURL: Stub.baseURL)
        await timeline.refresh(using: page(["c"]).handle, baseURL: Stub.baseURL)

        #expect(onDisk(root)?.memos.map(\.uid) == ["c"])
    }

    @Test("a write that throws leaves the previous snapshot where it was")
    func aFailedWriteKeepsThePreviousSnapshot() async {
        struct DiskFull: Error {}
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store(writer: writer(root: root))
            .refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)

        let refusing = store(writer: writer(root: root) { _, _ in throw DiskFull() })
        await refusing.refresh(using: page(["b"]).handle, baseURL: Stub.baseURL)

        #expect(refusing.memos.map(\.uid) == ["b"], "the failed write took the screen with it")
        #expect(onDisk(root)?.memos.map(\.uid) == ["a"], "the previous snapshot was destroyed")
    }

    @Test("a store with no identity to file one under keeps no snapshot")
    func noIdentityIsNoSnapshot() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let anonymous = TimelineStore(
            snapshots: writer(root: root),
            persists: true
        )

        await anonymous.refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        await anonymous.restoreSnapshot()

        #expect(anonymous.memos.map(\.uid) == ["a"], "control: the list itself loaded")
        #expect(
            !FileManager.default.fileExists(atPath: root.path),
            "a list with no identity to file it under wrote a file anyway"
        )
    }

    // MARK: - the session fence

    @Test("a page issued in one session and answered in the next reaches neither list nor disk")
    func aPageFromAnEndedSessionIsDropped() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let session = signedInSession(root: root) { _, _, operation in
            guard operation == listMemosOperation else { return Stub.json(Stub.user) }
            entered.set(true)
            while !release.get() {
                try await Task.sleep(for: .milliseconds(1))
            }
            return Stub.json(Stub.memoList(["late"], nextCursor: nil))
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        let timeline = store(writer: try #require(session.snapshots))
        timeline.reports(to: session)
        let handle = try #require(session.activeHandle)

        let inFlight = Task { await timeline.refresh(using: handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        // The device becomes nobody's while the page is in the air. The INCARNATION moves, which
        // is what a list is judged by.
        await session.signOutWithoutRevoking()
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

        let inFlight = Task { await timeline.refresh(using: client.handle, baseURL: Stub.baseURL) }
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
        epoch.bump()
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
        epoch.bump()
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

    // MARK: - a renewal is not the end of a session

    /// The fence that decides whether a page may land is the INCARNATION, never the authority
    /// epoch. They come apart on exactly one event, and this is it: a renewal replaces the token
    /// without ending the session. Judged by the authority epoch, every page in flight when a
    /// renewal landed would be dropped — and nothing retries a dropped page, so the list would
    /// simply stay as it was until something else asked.
    @Test("a renewal while a page is in flight leaves the list it was asked for standing")
    func aRenewalDoesNotVoidAPageInFlight() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let session = signedInSession(root: root) { _, _, operation in
            switch operation {
            case listMemosOperation:
                entered.set(true)
                while !release.get() {
                    try await Task.sleep(for: .milliseconds(1))
                }
                return Stub.json(Stub.memoList(["late"], nextCursor: nil))
            case tokenRenewOperation:
                return Stub.json(Stub.exchange(token: "memos_pat_next"))
            case tokenReadOperation:
                return Stub.json(Stub.nativeToken(name: "Fabian's iPhone"))
            default:
                return Stub.json(Stub.user)
            }
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_first")
        let timeline = store(writer: try #require(session.snapshots))
        timeline.reports(to: session)
        let handle = try #require(session.activeHandle)
        let incarnation = session.sessionIncarnation.current
        let authority = session.epoch.current

        let inFlight = Task { await timeline.refresh(using: handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        // The credential is replaced while the page is on the wire.
        let outcome = await session.renewDeviceToken()
        release.set(true)
        await inFlight.value

        #expect(outcome == .renewed, "control: the renewal happened")
        #expect(
            session.epoch.current != authority,
            "control: a renewal moves the AUTHORITY epoch — without that this case proves nothing"
        )
        #expect(
            session.sessionIncarnation.current == incarnation,
            "control: a renewal is not the end of an incarnation"
        )
        #expect(
            timeline.memos.map(\.uid) == ["late"],
            "a renewal voided a page in flight, and nothing retries one"
        )
    }

    /// The order the wipe happens in, made observable at the one moment it can be: the removal
    /// itself. `endIncarnation` runs first and moves the authority epoch, so a picture already on
    /// its way to the writer is stamped with a number that is no longer current and is refused
    /// there. Wiped first and ended after, that same picture would be accepted — and would land
    /// behind the removal, leaving one account's memos on a device nobody is signed in to.
    @Test("the snapshot is wiped under an incarnation that has already ended")
    func theWipeRunsAfterTheIncarnationEnded() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let authorityBox = LockedValue<SessionEpoch?>(nil)
        let atWipe = LockedValue<Int?>(nil)
        let session = sessionStore(
            root: root,
            removeItem: { url in
                atWipe.set(authorityBox.get()?.current)
                try FileManager.default.removeItem(at: url)
            }
        )
        authorityBox.set(session.epoch)
        let timeline = store(writer: try #require(session.snapshots))
        await timeline.refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        #expect(exists(root), "control: a snapshot was written")
        let before = session.epoch.current

        await session.signOutWithoutRevoking()

        #expect(!exists(root), "the snapshot outlived the credential")
        // Control: the removal really ran — a nil here is a case that proved nothing.
        let observed = try #require(atWipe.get())
        #expect(
            observed > before,
            "the wipe ran under an epoch that had not moved: a picture on its way would land"
        )
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

        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.count == 100, "the loaded list is not what was kept")

        let deleted = await timeline.delete(uid: "memo-7", using: client.handle)

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
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(timeline.memos.map(\.uid) == ["anchored"], "control: the anchored list loaded")
        #expect(!exists(root), "control: an anchored list is not written down")

        // The anchor is cleared — but the rows are the anchored day's until a refresh replaces
        // them, and a confirmed change to them is still a change to THAT list.
        timeline.setQuery(.empty)
        let deleted = await timeline.delete(uid: "anchored", using: client.handle)

        #expect(deleted, "control: the server confirmed the delete")
        #expect(!exists(root), "rows admitted under an anchor were written as the timeline")

        // And a load that really does replace them with the plain timeline is written.
        await timeline.refresh(using: page(["plain"]).handle, baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.map(\.uid) == ["plain"], "control: the plain list is kept")
    }

    @Test("a store its owner says is not the timeline never writes")
    func aStoreThatDoesNotPersistNeverWrites() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = writer(root: root)
        let results = store(writer: shared, persists: false)

        await results.refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)

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
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(
            onDisk(root)?.memos.map(\.content) == ["- [ ] task", "b"],
            "control: the loaded list was written down"
        )

        let ticking = Task {
            await timeline.toggleTask(at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL)
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
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)

        let first = Task {
            await timeline.toggleTask(at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        let second = await timeline.toggleTask(
            at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL
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

        await store(writer: shared).refresh(using: page(["a"]).handle, baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.map(\.uid) == ["a"], "control: the first store wrote")

        // The screen is torn down and made again — a second store, the same identity, numbering
        // its own changes from scratch.
        await store(writer: shared).refresh(using: page(["b"]).handle, baseURL: Stub.baseURL)

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
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.count == 2, "control: the plain list was written")

        // A day has been chosen; its page has not come back. The rows are still the plain
        // timeline's, and the next thing this store does is replace them.
        timeline.setQuery(MemoQuery(anchor: .day(year: 2026, month: 8, day: 23)))
        let deleted = await timeline.delete(uid: "other", using: client.handle)

        #expect(deleted, "control: the server confirmed the delete")
        #expect(onDisk(root)?.memos.count == 2, "a list under a requested anchor was written")
    }

    // MARK: - what the new awaits opened (review round 2)

    /// A sign-in that has been superseded while its own wipe was on the writer must not go on to
    /// write its credential: the device belongs to whoever came after it.
    @Test("a sign-in overtaken inside the snapshot wipe writes no credential")
    func aSupersededSignInWritesNothing() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let credentials = CountingCredentials()
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            snapshots: TimelineSnapshotStore(
                root: root,
                removeItem: { url in
                    entered.set(true)
                    // Long enough for the sign-out below to take the session away while this
                    // sign-in is still inside its own wipe.
                    Thread.sleep(forTimeInterval: 0.05)
                    try? FileManager.default.removeItem(at: url)
                }
            )
        )

        let signingIn = Task {
            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_new")
        }
        while !entered.get() {
            await Task.yield()
        }
        await session.signOutWithoutRevoking()
        await signingIn.value

        #expect(
            credentials.writeCount == 0,
            "a sign-in that no longer owned the session stored its credential anyway"
        )
    }

    /// The mirror: a sign-out that has been superseded while its wipe was on the writer must not
    /// delete the credential the NEWER sign-in has just stored.
    @Test("a sign-out overtaken inside the snapshot wipe deletes no credential")
    func aSupersededSignOutDeletesNothing() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let credentials = CountingCredentials()
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            snapshots: TimelineSnapshotStore(
                root: root,
                removeItem: { url in
                    entered.set(true)
                    Thread.sleep(forTimeInterval: 0.05)
                    try? FileManager.default.removeItem(at: url)
                }
            )
        )

        let signingOut = Task { await session.signOutWithoutRevoking() }
        while !entered.get() {
            await Task.yield()
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_new")
        await signingOut.value

        #expect(
            credentials.removeCount == 0,
            "a sign-out that no longer owned the session deleted a newer credential"
        )
        #expect(
            credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_new",
            "control: the newer sign-in did store its credential"
        )
    }

    /// The launch check clears the timeline an interrupted account switch left, and that removal
    /// is an await. A session that ended inside it must not have this stored credential admitted
    /// on top of whatever came next.
    @Test("a launch check overtaken inside the snapshot wipe admits nothing")
    func aSupersededRestoreAdmitsNothing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let credentials = CountingCredentials()
        try credentials.set("memos_pat_good", for: SessionStore.tokenAccount)
        try credentials.set(Stub.baseURL.absoluteString, for: SessionStore.serverAccount)
        let account = SpyAccountStore()
        account.publish(
            AccountBinding(
                serverBaseURL: URL(string: "https://other.example.invalid")!,
                ownerSubject: "somebody-else"
            )
        )
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            account: account,
            snapshots: TimelineSnapshotStore(
                root: root,
                removeItem: { url in
                    entered.set(true)
                    Thread.sleep(forTimeInterval: 0.05)
                    try? FileManager.default.removeItem(at: url)
                }
            )
        )

        let restoring = Task { await session.restore() }
        while !entered.get() {
            await Task.yield()
        }
        await session.signOutWithoutRevoking()
        await restoring.value

        #expect(
            session.state.user == nil,
            "a launch check admitted a credential for a session that had already ended"
        )
    }

    /// A tap taken while the first one's answer is still landing must not be RETIRED by that
    /// answer: the claim under a memo belongs to whoever made it, and a settle that removed
    /// whatever it found would let a third request overlap the second.
    @Test("a settle does not retire a claim made while its own answer was landing")
    func aSettleDoesNotRetireAClaimMadeWhileItLanded() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let patches = Counter()
        let writes = Counter()
        let applying = LockedValue<Bool>(false)
        let releaseWrite = LockedValue<Bool>(false)
        let releasePatch = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            guard operation.contains("patch_memo") else {
                return Stub.json(Stub.page([Stub.memo(uid: "a", content: "- [ ] task")]))
            }
            patches.increment()
            // The FIRST answer comes straight back; every later one is held, so a claim made
            // while the first was landing is still outstanding when the third tap is tried.
            if patches.count > 1 {
                while !releasePatch.get() {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            return Stub.json(Stub.memo(uid: "a", content: "- [x] task"))
        }
        let shared = writer(root: root) { data, url in
            writes.increment()
            // The load's own picture goes straight through. The next one is the tap's, and
            // holding it open is what gives a second tap somewhere to land.
            if writes.count > 1 {
                applying.set(true)
                while !releaseWrite.get() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            try data.write(to: url, options: .atomic)
        }
        let timeline = store(writer: shared)
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)

        let first = Task {
            await timeline.toggleTask(at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        while !applying.get() {
            await Task.yield()
        }
        let second = Task {
            await timeline.toggleTask(at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        while patches.count < 2 {
            await Task.yield()
        }
        releaseWrite.set(true)
        let ticked = await first.value
        // The second tap is still on the wire. A third must find its claim, not a hole the first
        // one's settle punched in it.
        let third = await timeline.toggleTask(
            at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL
        )
        releasePatch.set(true)
        _ = await second.value

        #expect(ticked, "control: the first tap went through")
        #expect(!third, "a third tap was taken while the second was still outstanding")
        #expect(patches.count == 2, "the first answer's settle admitted a third request")
    }

    /// A claim belongs to the tap that made it. An identity change empties the claims, the next
    /// tap makes a new one, and the settle of the tap from BEFORE the change must not retire it.
    @Test("a settle from before an identity change does not retire the claim made after it")
    func aStaleSettleDoesNotRetireANewerClaim() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let patches = Counter()
        let releaseFirst = LockedValue<Bool>(false)
        let releaseSecond = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            guard operation.contains("patch_memo") else {
                return Stub.json(Stub.page([Stub.memo(uid: "a", content: "- [ ] task")]))
            }
            patches.increment()
            let mine = patches.count
            while mine == 1 ? !releaseFirst.get() : !releaseSecond.get() {
                try await Task.sleep(for: .milliseconds(1))
            }
            return Stub.json(Stub.memo(uid: "a", content: "- [x] task"))
        }
        let timeline = store(writer: writer(root: root))
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)

        let outgoing = Task {
            await timeline.toggleTask(at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        while patches.count < 1 {
            await Task.yield()
        }
        // The device becomes somebody else's, which empties the claims this store was holding.
        timeline.sessionIdentityChanged(
            to: TimelineSnapshotIdentity(server: Stub.baseURL, subject: "somebody-else")
        )
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
        let incoming = Task {
            await timeline.toggleTask(at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        while patches.count < 2 {
            await Task.yield()
        }
        // Only now does the FIRST answer come back, so its settle runs with the incoming tap's
        // claim sitting under the same uid.
        releaseFirst.set(true)
        _ = await outgoing.value

        let third = await timeline.toggleTask(
            at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL
        )
        releaseSecond.set(true)
        _ = await incoming.value

        #expect(!third, "a third tap was taken while the second was still outstanding")
        #expect(patches.count == 2, "the settle of a retired tap admitted a third request")
    }

    /// A snapshot read spans two awaits, and a session can end inside either. What comes back is
    /// judged against the incarnation that ASKED for it, not against whoever is signed in when the
    /// bytes arrive — nobody has to tell this store anything for that to hold.
    @Test("a snapshot read under a session that has since ended is not rendered")
    func aSnapshotReadAcrossASessionEndIsNotRendered() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(to: root)
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        // The session moves the incarnation and keeps NO snapshots of its own, so the file this
        // case is about survives the sign-out and the read really does have something to render.
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        let shared = writer(root: root) { data, url in
            entered.set(true)
            while !release.get() {
                Thread.sleep(forTimeInterval: 0.005)
            }
            try data.write(to: url, options: .atomic)
        }
        let occupier = store(writer: shared, identity: identity)
        let timeline = store(writer: shared)
        timeline.reports(to: session)
        // Occupies the writer, so the restore below is suspended on it rather than racing.
        let busy = Task {
            await occupier.refresh(using: page(["occupier"]).handle, baseURL: Stub.baseURL)
        }
        while !entered.get() {
            await Task.yield()
        }
        let restoring = Task { await timeline.restoreSnapshot() }
        // The restore is on this actor and has nothing to do but reach the writer and stop.
        for _ in 0..<50 {
            await Task.yield()
        }

        await session.signOutWithoutRevoking()
        release.set(true)
        await busy.value
        await restoring.value

        #expect(
            timeline.memos.isEmpty,
            "a snapshot read as one person was rendered for a device that had become nobody's"
        )
    }

    /// The picture is stamped with the authority the operation was ISSUED under. A renewal that
    /// lands while the request is out replaces the credential, so the writer refuses the picture —
    /// while the list itself, judged by the incarnation, takes the answer.
    @Test("a picture issued before a renewal is refused, and the list still applies")
    func aPictureKeepsTheAuthorityItWasIssuedUnder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let session = signedInSession(root: root) { _, _, operation in
            switch operation {
            case tokenRenewOperation:
                return Stub.json(Stub.exchange(token: "memos_pat_next"))
            case tokenReadOperation:
                return Stub.json(Stub.nativeToken(name: "Fabian's iPhone"))
            case let op where op.contains("delete_memo"):
                entered.set(true)
                while !release.get() {
                    try await Task.sleep(for: .milliseconds(1))
                }
                return Stub.empty(.noContent)
            case listMemosOperation:
                return Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
            default:
                return Stub.json(Stub.user)
            }
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_first")
        let timeline = store(writer: try #require(session.snapshots))
        timeline.reports(to: session)
        let handle = try #require(session.activeHandle)
        await timeline.refresh(using: handle, baseURL: Stub.baseURL)
        #expect(onDisk(root)?.memos.map(\.uid) == ["a", "b"], "control: the load was written down")

        let deleting = Task { await timeline.delete(uid: "a", using: handle) }
        while !entered.get() {
            await Task.yield()
        }
        _ = await session.renewDeviceToken()
        release.set(true)
        let deleted = await deleting.value

        #expect(deleted, "control: the server confirmed the delete")
        #expect(timeline.memos.map(\.uid) == ["b"], "the list did not take its own answer")
        #expect(
            onDisk(root)?.memos.map(\.uid) == ["a", "b"],
            "a picture stamped with an authority the request never had was written"
        )
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

/// An in-memory keychain that COUNTS what was asked of it.
///
/// The final contents cannot answer these cases: a superseded write followed by somebody else's
/// delete, and a superseded delete followed by somebody else's write, both end in a state that
/// looks innocent. What was ASKED is the fact.
private final class CountingCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var writes = 0
    private var removals = 0

    func set(_ value: String, for account: String) throws {
        lock.withLock {
            storage[account] = value
            writes += 1
        }
    }

    func string(for account: String) throws -> String? { lock.withLock { storage[account] } }

    func remove(_ account: String) throws {
        lock.withLock {
            storage.removeValue(forKey: account)
            removals += 1
        }
    }

    var writeCount: Int { lock.withLock { writes } }
    var removeCount: Int { lock.withLock { removals } }
    func snapshot() -> [String: String] { lock.withLock { storage } }
}
