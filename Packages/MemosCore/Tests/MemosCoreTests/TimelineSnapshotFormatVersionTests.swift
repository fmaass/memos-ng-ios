import Foundation
import Testing

@testable import MemosCore

/// The version a snapshot written before pictures carried their capture instant was stamped with.
///
/// Written out as the literal it was rather than derived from the current number: derived, it would
/// follow every future bump and stop naming the file this suite is about.
private let versionBeforeCaptureInstants = 1

/// The version a snapshot written before attachments carried their civil capture clock, its source
/// and their owner's flag was stamped with (MEMNG-860). A literal, for the same reason.
private let versionBeforeAttachmentOwnership = 2

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
}

private let identity = TimelineSnapshotIdentity(
    server: URL(string: "https://memos.example")!, subject: "fabian"
)

/// What a snapshot from before this app knew when a picture was taken is worth.
@Suite("A timeline snapshot and the shape it was written in")
struct TimelineSnapshotFormatVersionTests {
    @Test("a snapshot written before pictures carried their capture instant reads as absent")
    func theOlderShapeIsNotRead() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TimelineSnapshotStore(root: root)
        let snapshot = TimelineSnapshot(
            formatVersion: versionBeforeCaptureInstants,
            identity: identity,
            query: MemoQuery(),
            revision: 1,
            writtenAt: Date(),
            memos: []
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: root.appending(path: identity.fileName))

        #expect(store.read(identity: identity) == nil)
        // The control, and the point: the same file under the current number is read, so what the
        // assertion above caught is the version and not a snapshot this store cannot read at all.
        #expect(TimelineSnapshot.currentFormatVersion == 3)
        var current = snapshot
        current.formatVersion = TimelineSnapshot.currentFormatVersion
        try JSONEncoder().encode(current).write(to: root.appending(path: identity.fileName))
        #expect(store.read(identity: identity) != nil)
    }

    @Test("a snapshot from before attachments carried their owner and civil clock reads as absent")
    func theShapeBeforeOwnershipIsNotRead() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TimelineSnapshotStore(root: root)
        let snapshot = TimelineSnapshot(
            formatVersion: versionBeforeAttachmentOwnership,
            identity: identity,
            query: MemoQuery(),
            revision: 1,
            writtenAt: Date(),
            memos: []
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: root.appending(path: identity.fileName))

        #expect(store.read(identity: identity) == nil)
        // The control: the same file under the current number is read.
        var current = snapshot
        current.formatVersion = TimelineSnapshot.currentFormatVersion
        try JSONEncoder().encode(current).write(to: root.appending(path: identity.fileName))
        #expect(store.read(identity: identity) != nil)
    }

    @Test("a snapshot written now keeps each picture's civil clock, its source and its owner")
    func theOwnershipSurvivesARoundTrip() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TimelineSnapshotStore(root: root)
        let memo = Memo(
            uid: "a", owner: "fabian", mine: true, content: "hello", visibility: .private,
            pinned: false, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            attachments: [
                MemoAttachment(
                    uid: "p1", mime: "image/jpeg", status: .ready,
                    captureCivil: "2026-01-01T13:00:00", captureSource: "exif", mine: false)
            ]
        )

        store.write([memo], for: identity, revision: 1, query: MemoQuery())

        let read = try #require(store.read(identity: identity))
        #expect(read.memos[0].attachments[0].captureCivil == "2026-01-01T13:00:00")
        #expect(read.memos[0].attachments[0].captureSource == "exif")
        #expect(read.memos[0].attachments[0].mine == false)
    }

    @Test("a snapshot written now keeps the instant each picture was taken at")
    func theCaptureInstantSurvivesARoundTrip() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TimelineSnapshotStore(root: root)
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        let memo = Memo(
            uid: "a",
            owner: "fabian",
            mine: true,
            content: "hello",
            visibility: .private,
            pinned: false,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            attachments: [
                MemoAttachment(
                    uid: "p1", mime: "image/jpeg", status: .ready, captureInstant: taken),
                MemoAttachment(uid: "p2", mime: "image/jpeg", status: .ready),
            ]
        )

        store.write([memo], for: identity, revision: 1, query: MemoQuery())

        let read = try #require(store.read(identity: identity))
        #expect(read.memos[0].attachments[0].captureInstant == taken)
        // Undated is the ordinary case — a screenshot, a drawing, a file stripped of its metadata —
        // and it has to survive the round trip as the absence it is rather than as some epoch.
        #expect(read.memos[0].attachments[1].captureInstant == nil)
    }
}
