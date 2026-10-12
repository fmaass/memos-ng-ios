import Foundation
@testable import MemosCore
import Testing

/// The pin file of server-backed trips, held to what the device-local trip file was held to
/// (MEMNG-754 adapted the device-local trip store's pin and file cases here): what reaches
/// `<scope>/pins.json`, what comes back from it through a SECOND instance over the same root, and
/// whose file it is.
@MainActor
@Suite("Trip pins — the file")
struct TripPinsFileTests {
    private let root = TripWire.root()
    private let march12 = Date(timeIntervalSince1970: 1_773_304_200)  // 2026-03-12T08:30:00Z
    private let march28 = Date(timeIntervalSince1970: 1_774_720_800)  // 2026-03-28T18:00:00Z
    private let april4 = Date(timeIntervalSince1970: 1_775_325_600)  // 2026-04-04T18:00:00Z
    private let april11 = Date(timeIntervalSince1970: 1_775_930_400)  // 2026-04-11T18:00:00Z
    private let october7 = Date(timeIntervalSince1970: 1_791_374_400)  // 2026-10-07T12:00:00Z
    private let october14 = Date(timeIntervalSince1970: 1_791_979_200)  // 2026-10-14T12:00:00Z

    private struct WriteDied: Error {}

    private func pins(
        _ identity: TimelineSnapshotIdentity? = TripWire.alice,
        writeBytes: ((Data, URL) throws -> Void)? = nil
    ) -> TripPins {
        guard let writeBytes else { return TripPins(identity: identity, root: root) }
        return TripPins(identity: identity, root: root, writeBytes: writeBytes)
    }

    private func trip(_ uid: String, title: String = "Trip", tag: String? = "trip") -> Trip {
        Trip(uid: uid, title: title, tag: tag, createdAt: october7, updatedAt: october7)
    }

    private func scopeDirectory(_ identity: TimelineSnapshotIdentity) -> URL {
        root.appending(path: TripPins.scopeKey(for: identity))
    }

    private func fileURL(_ identity: TimelineSnapshotIdentity) -> URL {
        scopeDirectory(identity).appending(path: TripPins.fileName)
    }

    private func contents(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: - The row and its file

    @Test("every pin field survives a write and a fresh read, the date as ISO-8601 UTC")
    func roundTripOfEveryField() throws {
        let writer = pins()
        let portugal = trip("t1", title: "Portugal 2026", tag: "portugal2026")
        writer.pin(portugal, lastTaken: march28, now: october7)
        let expected = TripPin(
            uid: "t1", title: "Portugal 2026", tag: "portugal2026", pinnedUntil: april4)
        #expect(writer.rows == [expected])
        #expect(pins().rows == [expected])
        let text = try String(contentsOf: fileURL(TripWire.alice), encoding: .utf8)
        #expect(text.contains("\"2026-04-04T18:00:00Z\""))
        #expect(text.contains("\"formatVersion\" : 1"))
    }

    @Test("a pinned title and tag holding quotes, braces and a newline round-trip as written")
    func literalTitleRoundTrips() {
        let title = "Lisbon \"}] \n#notatag \\ end"
        pins().pin(trip("t1", title: title, tag: "a\"b"), lastTaken: nil, now: october7)
        #expect(pins().rows.map(\.title) == [title])
        #expect(pins().rows.map(\.tag) == ["a\"b"])
        #expect(pins().rows.map(\.uid) == ["t1"])
    }

    @Test("the scope key is a stable SHA-256 of server and subject")
    func scopeKeyIsStable() {
        let alice = TimelineSnapshotIdentity(
            server: URL(string: "https://memos.example.org")!, subject: "alice")
        let bob = TimelineSnapshotIdentity(
            server: URL(string: "https://memos.example.org")!, subject: "bob")
        #expect(
            TripPins.scopeKey(for: alice)
                == "2fadd696398bbc1c29a8a5a985567f0c09974af439ccf5ea7555c859d734b177")
        #expect(
            TripPins.scopeKey(for: bob)
                == "14113c8d6747916a0cf6def8f590493e2bc8c0ab4dd40e9192fddd6e9d4bb317")
        let otherServer = TimelineSnapshotIdentity(
            server: URL(string: "https://other.example.org")!, subject: "alice")
        #expect(TripPins.scopeKey(for: otherServer) != TripPins.scopeKey(for: alice))
    }

    // MARK: - The pin

    @Test("pin lasts seven days past the last picture, or past now without one, one at a time")
    func pinOneAtATime() {
        let writer = pins()
        writer.pin(trip("one"), lastTaken: march28, now: october7)
        #expect(pins().pinnedUntil(uid: "one") == april4)
        #expect(pins().pinnedUntil(uid: "two") == nil)
        writer.pin(trip("two"), lastTaken: nil, now: october7)
        #expect(pins().pinnedUntil(uid: "one") == nil)
        #expect(pins().pinnedUntil(uid: "two") == october14)
    }

    @Test("unpin clears the pin")
    func unpinClears() {
        let writer = pins()
        writer.pin(trip("t1"), lastTaken: nil, now: october7)
        writer.unpin(uid: "t1")
        #expect(pins().pinnedUntil(uid: "t1") == nil)
        #expect(pins().rows.isEmpty)
    }

    @Test("a later last picture through noteMembers moves the pin out, in one write")
    func noteMembersExtendsThePinInOneWrite() {
        let writes = Box(0)
        let writer = pins(writeBytes: { data, url in
            writes.value += 1
            try data.write(to: url)
        })
        writer.pin(trip("t1"), lastTaken: march28, now: october7)
        #expect(pins().pinnedUntil(uid: "t1") == april4, "precondition: march28 + 7 d")
        let before = writes.value
        // april4 is already behind the clock (october7): an expired pin is re-derived too,
        // because the rule is "seven days after its last picture".
        writer.noteMembers(uid: "t1", firstTaken: march12, lastTaken: april4, now: october7)
        #expect(writes.value == before + 1, "the extension is one write")
        #expect(pins().pinnedUntil(uid: "t1") == april11)
    }

    @Test("an earlier last picture, or none, never shortens the pin")
    func noteMembersNeverShortens() {
        let writer = pins()
        writer.pin(trip("t1"), lastTaken: april4, now: october7)
        #expect(pins().pinnedUntil(uid: "t1") == april11, "precondition: april4 + 7 d")
        writer.noteMembers(uid: "t1", firstTaken: march12, lastTaken: march28, now: october7)
        #expect(pins().pinnedUntil(uid: "t1") == april11, "an exclusion moved it earlier")
        writer.noteMembers(uid: "t1", firstTaken: nil, lastTaken: nil, now: october7)
        #expect(pins().pinnedUntil(uid: "t1") == april11, "a drain of no pictures dropped it")
    }

    @Test("noteMembers on an unpinned trip never pins it")
    func noteMembersNeverPins() {
        let writer = pins()
        writer.noteMembers(uid: "t1", firstTaken: march12, lastTaken: october7, now: october7)
        #expect(writer.rows.isEmpty)
        #expect(pins().pinnedUntil(uid: "t1") == nil)
    }

    @Test("another trip's members leave the pinned trip's expiry as it is")
    func anotherTripsMembers() {
        let writer = pins()
        writer.pin(trip("pinned"), lastTaken: march28, now: october7)
        writer.noteMembers(uid: "other", firstTaken: march12, lastTaken: october7, now: october7)
        #expect(pins().pinnedUntil(uid: "pinned") == april4)
        #expect(pins().pinnedUntil(uid: "other") == nil)
    }

    @Test("an extension whose write failed extends nothing, in memory or on disk")
    func aFailedExtensionWriteExtendsNothing() {
        pins().pin(trip("t1"), lastTaken: march28, now: october7)
        let dying = pins(writeBytes: { _, _ in throw WriteDied() })
        dying.noteMembers(uid: "t1", firstTaken: march12, lastTaken: april4, now: october7)
        #expect(dying.pinnedUntil(uid: "t1") == april4)
        #expect(pins().pinnedUntil(uid: "t1") == april4)
    }

    @Test("a pin is active strictly before its end: at the end it has expired, a second before not")
    func activePinBoundary() {
        let writer = pins()
        writer.pin(trip("t1"), lastTaken: nil, now: october7)
        #expect(writer.activePin(now: october14) == nil, "pinnedUntil == now is expired")
        #expect(writer.activePin(now: october14.addingTimeInterval(-1))?.uid == "t1")
        #expect(pins().activePin(now: october14.addingTimeInterval(-1))?.uid == "t1")
    }

    @Test("a trip with no pictures is pinned until seven days after the moment of pinning")
    func activePinWithoutPictures() {
        let writer = pins()
        writer.pin(trip("t1"), lastTaken: nil, now: october7)
        #expect(pins().pinnedUntil(uid: "t1") == october14)
        #expect(writer.activePin(now: october7)?.uid == "t1")
    }

    @Test("pinning a second trip makes it the only active pin; pinning twice changes nothing")
    func activePinOneAtATime() {
        let writer = pins()
        writer.pin(trip("one"), lastTaken: nil, now: october7)
        writer.pin(trip("two"), lastTaken: nil, now: october7)
        writer.pin(trip("two"), lastTaken: nil, now: october7)
        #expect(writer.activePin(now: october7)?.uid == "two")
        #expect(pins().rows.map(\.uid) == ["two"])
        #expect(pins().pinnedUntil(uid: "two") == october14)
    }

    @Test("an unpinned trip, and an expired pin, are no active pin")
    func activePinAfterUnpin() {
        let writer = pins()
        writer.pin(trip("t1"), lastTaken: march28, now: october7)
        #expect(writer.activePin(now: october7) == nil, "april4 is behind october7: expired")
        #expect(writer.activePin(now: march28)?.uid == "t1")
        writer.unpin(uid: "t1")
        #expect(writer.activePin(now: march28) == nil)
        #expect(pins().activePin(now: march28) == nil)
    }

    @Test("a hand-edited file with several pins: the longest wins, the first in order on a tie")
    func activePinOfSeveral() throws {
        struct HandFile: Encodable {
            var formatVersion: Int
            var pins: [TripPin]
        }
        let rows = [
            TripPin(uid: "A", title: "A", tag: "a", pinnedUntil: april4),
            TripPin(uid: "B", title: "B", tag: "b", pinnedUntil: april11),
            TripPin(uid: "C", title: "C", tag: "c", pinnedUntil: april11),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: scopeDirectory(TripWire.alice), withIntermediateDirectories: true)
        try encoder.encode(HandFile(formatVersion: 1, pins: rows)).write(
            to: fileURL(TripWire.alice))

        let reader = pins()
        #expect(reader.rows.count == 3, "precondition: read back")
        #expect(reader.activePin(now: march28)?.uid == "B")
        #expect(reader.activePin(now: april4)?.uid == "B")
        #expect(reader.activePin(now: april11) == nil)
    }

    @Test("the active pin is the signed-in scope's: B sees none of A's, A gets it back")
    func activePinIsScoped() {
        let session = pins()
        session.pin(trip("t1", title: "Portugal 2026"), lastTaken: nil, now: october7)
        session.sessionIdentityChanged(to: TripWire.bob)
        #expect(session.activePin(now: october7) == nil)
        session.sessionIdentityChanged(to: TripWire.alice)
        #expect(session.activePin(now: october7)?.uid == "t1")
    }

    // MARK: - Failure

    @Test("a file that will not decode is set aside as pins.json.bad-<id>; the scope starts empty")
    func badFileSetAside() throws {
        let directory = scopeDirectory(TripWire.alice)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: fileURL(TripWire.alice))

        let reader = pins()
        #expect(reader.rows.isEmpty)
        let bad = contents(directory).filter { $0.hasPrefix("\(TripPins.fileName).bad-") }
        #expect(bad.count == 1)
        let aside = directory.appending(path: bad.first ?? "missing")
        #expect(try Data(contentsOf: aside) == garbage)
        #expect(!FileManager.default.fileExists(atPath: fileURL(TripWire.alice).path))

        // The scope carries on, and the bad bytes are never written over.
        reader.pin(trip("fresh"), lastTaken: nil, now: october7)
        #expect(pins().rows.map(\.uid) == ["fresh"])
        #expect(try Data(contentsOf: aside) == garbage)
    }

    @Test("a valid file of another format version is set aside whole and the scope starts empty")
    func otherFormatVersionSetAside() throws {
        pins().pin(trip("t1"), lastTaken: nil, now: october7)
        let url = fileURL(TripWire.alice)
        let current = try String(contentsOf: url, encoding: .utf8)
        #expect(current.contains("\"formatVersion\" : 1"))
        let future = Data(
            current.replacingOccurrences(
                of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 2"
            ).utf8)
        try future.write(to: url)

        let reader = pins()
        #expect(reader.rows.isEmpty)
        let directory = scopeDirectory(TripWire.alice)
        let bad = contents(directory).filter { $0.hasPrefix("\(TripPins.fileName).bad-") }
        #expect(bad.count == 1)
        #expect(try Data(contentsOf: directory.appending(path: bad.first ?? "missing")) == future)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a bad file that cannot be moved aside is never written over")
    func unmovableBadFileStaysReadOnly() throws {
        let directory = scopeDirectory(TripWire.alice)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: fileURL(TripWire.alice))
        // A directory that takes no new entry: the move aside fails, and so would any write.
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }

        let stuck = pins()
        #expect(stuck.rows.isEmpty)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        stuck.pin(trip("fresh"), lastTaken: nil, now: october7)

        #expect(stuck.rows.isEmpty)
        #expect(try Data(contentsOf: fileURL(TripWire.alice)) == garbage)
        #expect(contents(directory) == [TripPins.fileName])
    }

    @Test("a second bad file does not overwrite the first copy")
    func secondBadFileKeepsFirst() throws {
        let directory = scopeDirectory(TripWire.alice)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: fileURL(TripWire.alice))
        _ = pins()
        try Data("second".utf8).write(to: fileURL(TripWire.alice))
        _ = pins()
        let bad = contents(directory).filter { $0.contains(".bad-") }
        #expect(bad.count == 2)
        let kept = try bad.map {
            try String(contentsOf: directory.appending(path: $0), encoding: .utf8)
        }
        #expect(Set(kept) == ["first", "second"])
    }

    @Test("a write that dies half way leaves the previous file whole and memory unchanged")
    func writeIsAtomic() throws {
        pins().pin(trip("t1", title: "Portugal 2026"), lastTaken: nil, now: october7)
        let before = pins().rows
        let dying = pins(writeBytes: { data, url in
            try data.prefix(data.count / 2).write(to: url)
            throw WriteDied()
        })
        dying.pin(trip("t2", title: "Lost"), lastTaken: nil, now: october7)
        dying.unpin(uid: "t1")

        #expect(dying.rows == before)
        #expect(pins().rows == before)
        // No half-written temporary is left behind, and nothing was set aside.
        #expect(contents(scopeDirectory(TripWire.alice)) == [TripPins.fileName])
    }

    // MARK: - Identity scope

    @Test("signing out of A and in to B shows nothing of A; back to A restores it")
    func identitySwitch() {
        let session = pins()
        session.pin(trip("t1", title: "Portugal 2026"), lastTaken: nil, now: october7)
        let aliceRows = session.rows
        #expect(!aliceRows.isEmpty)

        session.sessionIdentityChanged(to: nil)
        #expect(session.rows.isEmpty)
        #expect(session.identity == nil)

        session.sessionIdentityChanged(to: TripWire.bob)
        #expect(session.rows.isEmpty)
        session.pin(trip("b1", title: "Bob's"), lastTaken: nil, now: october7)
        let bobRows = session.rows

        session.sessionIdentityChanged(to: TripWire.alice)
        #expect(session.rows == aliceRows)

        // One directory per scope, each with its own file — nothing filed outside a scope.
        #expect(
            contents(root)
                == [TripPins.scopeKey(for: TripWire.alice), TripPins.scopeKey(for: TripWire.bob)]
                .sorted())
        #expect(pins(TripWire.bob).rows == bobRows)
    }

    @Test("with nobody signed in nothing is read, kept or written")
    func noIdentityWritesNothing() {
        let anonymous = pins(nil)
        anonymous.pin(trip("t1", title: "Nowhere"), lastTaken: nil, now: october7)
        #expect(anonymous.rows.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
