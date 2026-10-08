import Foundation
@testable import MemosCore
import Testing

/// The device-local trip records: what reaches the file, what comes back from it, and whose file
/// it is.
///
/// Every case drives the REAL `CollectionStore` over a fresh temporary root and reads the result
/// back through a SECOND store over the same root (or the bytes themselves), so nothing here
/// passes on what one instance merely remembers. `@testable` for `utcStamp` and the
/// initialiser that injects the move-aside step.
@MainActor
@Suite("Collection store")
struct CollectionStoreTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "collections")
        .appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.org")!,
        subject: "alice"
    )
    private let bob = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.org")!,
        subject: "bob"
    )
    private let march12 = Date(timeIntervalSince1970: 1_773_304_200)  // 2026-03-12T08:30:00Z
    private let march28 = Date(timeIntervalSince1970: 1_774_720_800)  // 2026-03-28T18:00:00Z
    private let april4 = Date(timeIntervalSince1970: 1_775_325_600)  // 2026-04-04T18:00:00Z
    private let october7 = Date(timeIntervalSince1970: 1_791_374_400)  // 2026-10-07T12:00:00Z
    private let october14 = Date(timeIntervalSince1970: 1_791_979_200)  // 2026-10-14T12:00:00Z

    private struct WriteDied: Error {}

    private func store(
        _ identity: TimelineSnapshotIdentity? = nil,
        writeBytes: ((Data, URL) throws -> Void)? = nil
    ) -> CollectionStore {
        let now = october7
        if let writeBytes {
            return CollectionStore(
                identity: identity ?? alice, root: root, now: { now }, writeBytes: writeBytes)
        }
        return CollectionStore(identity: identity ?? alice, root: root, now: { now })
    }

    private func scopeDirectory(_ identity: TimelineSnapshotIdentity) -> URL {
        root.appending(path: CollectionStore.scopeKey(for: identity))
    }

    private func fileURL(_ identity: TimelineSnapshotIdentity) -> URL {
        scopeDirectory(identity).appending(path: CollectionStore.fileName)
    }

    private func contents(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: - The record and its file

    @Test("every field survives a write and a fresh read, dates as ISO-8601 UTC")
    func roundTripOfEveryField() throws {
        let writer = store()
        let created = writer.create(title: "Portugal 2026", tags: ["portugal2026"])
        writer.setCover(id: created.id, uid: "att-cover")
        writer.exclude(id: created.id, uid: "att-gone")
        let summary = TripSummary(
            count: 42, firstTaken: march12, lastTaken: march28, coverUid: "att-first")
        writer.setSummary(id: created.id, summary)
        writer.pin(id: created.id, now: october7)

        let expected = CollectionRecord(
            id: created.id,
            kind: .trip,
            title: "Portugal 2026",
            tags: ["portugal2026"],
            coverUid: "att-cover",
            order: 0,
            pinnedUntil: april4,
            lastSummary: summary,
            excludedUids: ["att-gone"],
            createdAt: october7
        )
        #expect(writer.records == [expected])
        #expect(store().records == [expected])

        let text = try String(contentsOf: fileURL(alice), encoding: .utf8)
        #expect(text.contains("\"2026-03-12T08:30:00Z\""))
        #expect(text.contains("\"2026-03-28T18:00:00Z\""))
        #expect(text.contains("\"2026-04-04T18:00:00Z\""))
        #expect(text.contains("\"2026-10-07T12:00:00Z\""))
        #expect(text.contains("\"kind\" : \"trip\""))
    }

    @Test("a title holding quotes, braces and a newline round-trips as written")
    func literalTitleRoundTrips() {
        let title = "Lisbon \"}] \n#notatag \\ end"
        let created = store().create(title: title, tags: ["a\"b"])
        #expect(store().records.map(\.title) == [title])
        #expect(store().records.map(\.tags) == [["a\"b"]])
        #expect(store().records.map(\.id) == [created.id])
    }

    @Test("the scope key is a stable SHA-256 of server and subject")
    func scopeKeyIsStable() {
        #expect(
            CollectionStore.scopeKey(for: alice)
                == "2fadd696398bbc1c29a8a5a985567f0c09974af439ccf5ea7555c859d734b177")
        #expect(
            CollectionStore.scopeKey(for: bob)
                == "14113c8d6747916a0cf6def8f590493e2bc8c0ab4dd40e9192fddd6e9d4bb317")
        let otherServer = TimelineSnapshotIdentity(
            server: URL(string: "https://other.example.org")!, subject: "alice")
        #expect(CollectionStore.scopeKey(for: otherServer) != CollectionStore.scopeKey(for: alice))
    }

    // MARK: - Mutations

    @Test("create appends a trip at the end of the order with the clock's date")
    func createAppends() {
        let writer = store()
        let first = writer.create(title: "Portugal 2026", tags: ["portugal2026"])
        #expect(first.kind == .trip)
        #expect(first.order == 0)
        #expect(first.createdAt == october7)
        #expect(first.coverUid == nil && first.pinnedUntil == nil && first.lastSummary == nil)
        #expect(first.excludedUids.isEmpty)
        #expect(store().records == [first])
    }

    @Test("two creates in one turn are two records with distinct orders, both on disk")
    func twoCreatesInOneTurn() {
        let writer = store()
        let one = writer.create(title: "One", tags: ["one"])
        let two = writer.create(title: "Two", tags: ["two"])
        #expect(one.id != two.id)
        #expect(one.order != two.order)
        #expect(writer.records.map(\.title) == ["One", "Two"])
        #expect(store().records.map(\.title) == ["One", "Two"])
        #expect(Set(store().records.map(\.order)).count == 2)
    }

    @Test("rename changes the title and nothing else")
    func renameChangesTitle() {
        let writer = store()
        let created = writer.create(title: "Portugal", tags: ["portugal2026"])
        writer.rename(id: created.id, to: "Portugal 2026")
        var expected = created
        expected.title = "Portugal 2026"
        #expect(writer.records == [expected])
        #expect(store().records == [expected])
    }

    @Test("delete removes the record from memory and file, leaving the others")
    func deleteRemoves() {
        let writer = store()
        let one = writer.create(title: "One", tags: ["one"])
        let two = writer.create(title: "Two", tags: ["two"])
        writer.delete(id: one.id)
        #expect(writer.records == [two])
        #expect(store().records == [two])
    }

    @Test("move reorders, renumbers and the order survives a reload")
    func moveReorders() {
        let writer = store()
        let one = writer.create(title: "One", tags: ["one"])
        _ = writer.create(title: "Two", tags: ["two"])
        let three = writer.create(title: "Three", tags: ["three"])
        writer.move(id: three.id, to: 0)
        #expect(writer.records.map(\.title) == ["Three", "One", "Two"])
        #expect(writer.records.map(\.order) == [0, 1, 2])
        #expect(store().records.map(\.title) == ["Three", "One", "Two"])
        // Past the end clamps to the end; a negative index to the front.
        writer.move(id: three.id, to: 99)
        #expect(store().records.map(\.title) == ["One", "Two", "Three"])
        writer.move(id: one.id, to: -5)
        #expect(store().records.map(\.title) == ["One", "Two", "Three"])
        // A record that is NOT first, moved to a negative index, becomes first.
        writer.move(id: three.id, to: -1)
        #expect(writer.records.map(\.title) == ["Three", "One", "Two"])
        #expect(store().records.map(\.title) == ["Three", "One", "Two"])
        #expect(store().records.map(\.order) == [0, 1, 2])
    }

    @Test("order is stable across reloads with no mutation in between")
    func orderStableAcrossReload() {
        let writer = store()
        for title in ["A", "B", "C", "D"] { writer.create(title: title, tags: [title]) }
        let first = store().records
        let second = store().records
        #expect(first.map(\.title) == ["A", "B", "C", "D"])
        #expect(first == second)
    }

    @Test("move of a single record, and any mutation of an unknown id, writes nothing new")
    func boundaryMutations() {
        let writer = store()
        let only = writer.create(title: "Only", tags: ["only"])
        writer.move(id: only.id, to: 3)
        #expect(store().records == [only])
        writer.rename(id: UUID(), to: "Ghost")
        writer.delete(id: UUID())
        writer.pin(id: UUID(), now: october7)
        #expect(store().records == [only])
    }

    @Test("setCover picks a cover and nil goes back to the first member")
    func setCover() {
        let writer = store()
        let created = writer.create(title: "Trip", tags: ["trip"])
        writer.setCover(id: created.id, uid: "att-7")
        #expect(store().records.first?.coverUid == "att-7")
        writer.setCover(id: created.id, uid: nil)
        #expect(store().records.first?.coverUid == nil)
    }

    @Test("exclude adds a uid once; include takes it out")
    func excludeAndInclude() {
        let writer = store()
        let created = writer.create(title: "Trip", tags: ["trip"])
        writer.exclude(id: created.id, uid: "att-1")
        writer.exclude(id: created.id, uid: "att-2")
        writer.exclude(id: created.id, uid: "att-1")
        #expect(store().records.first?.excludedUids == ["att-1", "att-2"])
        writer.include(id: created.id, uid: "att-1")
        #expect(store().records.first?.excludedUids == ["att-2"])
    }

    @Test("pin lasts seven days past the last picture, or past now without one, one at a time")
    func pinOneAtATime() {
        let writer = store()
        let one = writer.create(title: "One", tags: ["one"])
        let two = writer.create(title: "Two", tags: ["two"])
        writer.setSummary(
            id: one.id,
            TripSummary(count: 3, firstTaken: march12, lastTaken: march28, coverUid: "c"))
        writer.pin(id: one.id, now: october7)
        #expect(store().records.map(\.pinnedUntil) == [april4, nil])
        writer.pin(id: two.id, now: october7)
        #expect(store().records.map(\.pinnedUntil) == [nil, october14])
    }

    @Test("unpin clears the pin")
    func unpinClears() {
        let writer = store()
        let created = writer.create(title: "Trip", tags: ["trip"])
        writer.pin(id: created.id, now: october7)
        writer.unpin(id: created.id)
        #expect(store().records.first?.pinnedUntil == nil)
    }

    @Test("setSummary writes the summary and nil clears it")
    func setSummary() {
        let writer = store()
        let created = writer.create(title: "Trip", tags: ["trip"])
        let summary = TripSummary(count: 0, firstTaken: nil, lastTaken: nil, coverUid: nil)
        writer.setSummary(id: created.id, summary)
        #expect(store().records.first?.lastSummary == summary)
        writer.setSummary(id: created.id, nil)
        #expect(store().records.first?.lastSummary == nil)
    }

    // MARK: - Failure

    @Test("a file that will not decode is set aside as .bad-<utc> and the store starts empty")
    func badFileSetAside() throws {
        try FileManager.default.createDirectory(
            at: scopeDirectory(alice), withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: fileURL(alice))

        let reader = store()
        #expect(reader.records.isEmpty)
        let aside = scopeDirectory(alice).appending(
            path: "collections.json.bad-\(CollectionStore.utcStamp(october7))")
        #expect(CollectionStore.utcStamp(october7) == "20261007T120000Z")
        #expect(try Data(contentsOf: aside) == garbage)
        #expect(!FileManager.default.fileExists(atPath: fileURL(alice).path))

        // The scope carries on, and the bad bytes are never written over.
        reader.create(title: "Fresh", tags: ["fresh"])
        #expect(store().records.map(\.title) == ["Fresh"])
        #expect(try Data(contentsOf: aside) == garbage)
    }

    @Test("a valid file of another format version is set aside whole and the store starts empty")
    func otherFormatVersionSetAside() throws {
        store().create(title: "Portugal 2026", tags: ["portugal2026"])
        let current = try String(contentsOf: fileURL(alice), encoding: .utf8)
        #expect(current.contains("\"formatVersion\" : 1"))
        let future = Data(
            current.replacingOccurrences(
                of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 2"
            ).utf8)
        try future.write(to: fileURL(alice))

        let reader = store()
        #expect(reader.records.isEmpty)
        let aside = scopeDirectory(alice).appending(path: "collections.json.bad-20261007T120000Z")
        #expect(try Data(contentsOf: aside) == future)
        #expect(!FileManager.default.fileExists(atPath: fileURL(alice).path))
    }

    @Test("a bad file that cannot be moved aside is never written over")
    func unmovableBadFileStaysReadOnly() throws {
        try FileManager.default.createDirectory(
            at: scopeDirectory(alice), withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: fileURL(alice))

        let now = october7
        let stuck = CollectionStore(
            identity: alice,
            root: root,
            now: { now },
            writeBytes: { try $0.write(to: $1) },
            moveAside: { _, _ in throw WriteDied() }
        )
        #expect(stuck.records.isEmpty)
        let made = stuck.create(title: "Fresh", tags: ["fresh"])
        stuck.rename(id: made.id, to: "Renamed")

        #expect(stuck.records.isEmpty)
        #expect(try Data(contentsOf: fileURL(alice)) == garbage)
        #expect(contents(scopeDirectory(alice)) == [CollectionStore.fileName])
    }

    @Test("a second bad file in the same second does not overwrite the first copy")
    func secondBadFileKeepsFirst() throws {
        try FileManager.default.createDirectory(
            at: scopeDirectory(alice), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: fileURL(alice))
        _ = store()
        try Data("second".utf8).write(to: fileURL(alice))
        _ = store()
        let bad = contents(scopeDirectory(alice)).filter { $0.contains(".bad-") }
        #expect(bad.count == 2)
        let kept = try bad.map {
            try String(contentsOf: scopeDirectory(alice).appending(path: $0), encoding: .utf8)
        }
        #expect(Set(kept) == ["first", "second"])
    }

    @Test("a write that dies half way leaves the previous file whole and memory unchanged")
    func writeIsAtomic() throws {
        let created = store().create(title: "Portugal 2026", tags: ["portugal2026"])
        let dying = store(
            writeBytes: { data, url in
                try data.prefix(data.count / 2).write(to: url)
                throw WriteDied()
            })
        dying.rename(id: created.id, to: "Changed")
        dying.create(title: "Lost", tags: ["lost"])

        #expect(dying.records == [created])
        #expect(store().records == [created])
        // No half-written temporary is left behind, and nothing was set aside.
        #expect(contents(scopeDirectory(alice)) == [CollectionStore.fileName])
    }

    // MARK: - Identity scope

    @Test("signing out of A and in to B shows nothing of A; back to A restores it")
    func identitySwitch() {
        let session = store(alice)
        let trip = session.create(title: "Portugal 2026", tags: ["portugal2026"])
        session.pin(id: trip.id, now: october7)
        let aliceRecords = session.records
        #expect(aliceRecords.first?.pinnedUntil != nil)

        session.sessionIdentityChanged(to: nil)
        #expect(session.records.isEmpty)
        #expect(session.identity == nil)

        session.sessionIdentityChanged(to: bob)
        #expect(session.records.isEmpty)
        #expect(!session.records.contains { $0.pinnedUntil != nil })
        #expect(!session.records.contains { $0.title == "Portugal 2026" })
        let bobTrip = session.create(title: "Bob's", tags: ["bob"])
        #expect(session.records == [bobTrip])

        session.sessionIdentityChanged(to: alice)
        #expect(session.records == aliceRecords)

        // One directory per scope, each with its own file — nothing filed outside a scope.
        #expect(
            contents(root)
                == [CollectionStore.scopeKey(for: alice), CollectionStore.scopeKey(for: bob)]
                .sorted())
        #expect(store(bob).records == [bobTrip])
    }

    @Test("with nobody signed in nothing is read, kept or written")
    func noIdentityWritesNothing() {
        let now = october7
        let anonymous = CollectionStore(identity: nil, root: root, now: { now })
        let made = anonymous.create(title: "Nowhere", tags: ["nowhere"])
        #expect(made.title == "Nowhere")
        #expect(anonymous.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
