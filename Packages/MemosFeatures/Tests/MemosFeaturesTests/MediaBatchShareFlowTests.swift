import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

private func row(_ uid: String, filename: String, mime: String = "image/jpeg") -> LibraryRow {
    LibraryRow(
        attachment: MemoAttachment(
            uid: uid,
            mime: mime,
            status: .ready,
            downloadURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/o")
        ),
        takenAt: nil,
        mine: true,
        filename: filename
    )
}

/// A file in the shape `OriginalMedia.fetch` leaves one: real bytes, named `uid.ext`, inside an
/// enclosure directory of its own — what a rename happens inside and what a discard removes.
private func fetchedFile(_ name: String) throws -> URL {
    let enclosure = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: enclosure, withIntermediateDirectories: true)
    let file = enclosure.appending(path: name)
    try Data("bytes".utf8).write(to: file)
    return file
}

/// What a flow threw away. Locked and nonisolated for the reason `MediaSaveFlowTests`' is: a
/// release can run from a `deinit`, on no actor.
private nonisolated final class Removals: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ files: [URL]) {
        lock.lock()
        urls += files
        lock.unlock()
    }

    var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

/// What the download closure was asked for, in order.
@MainActor
private final class Requests {
    private(set) var asked: [(uid: String, rendition: AttachmentRendition)] = []
    func record(_ attachment: MemoAttachment, _ rendition: AttachmentRendition) {
        asked.append((attachment.uid, rendition))
    }
}

/// The session generation as a test moves it.
@MainActor
private final class Generation {
    var value: Int? = 7
}

/// A download the test holds open until it chooses to answer it.
@MainActor
private final class HeldDownload {
    private var continuation: CheckedContinuation<URL, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async -> URL {
        await withCheckedContinuation { continuation = $0 }
    }

    func answer(_ file: URL) {
        continuation?.resume(returning: file)
        continuation = nil
    }

    /// Yields until the flow is parked in `wait`, boundedly.
    func parked() async -> Bool {
        for _ in 0..<1000 where !isWaiting { await Task.yield() }
        return isWaiting
    }
}

/// Select mode's Share (MEMNG-588): the originals of the chosen pictures, one at a time, into one
/// share sheet — fenced once by the session it started under.
@MainActor
@Suite("Sharing a selection")
struct MediaBatchShareFlowTests {
    @Test("a file keeps the name it was uploaded under")
    func theUploadedNameIsKept() throws {
        let named = row("u1", filename: "Holiday 2026.HEIC")
        #expect(MediaBatchShareFlow.shareName(for: named) == "Holiday 2026.HEIC")
    }

    @Test("a file with no name is called by its uid and the original's extension")
    func anEmptyNameFallsBackToTheUid() {
        #expect(MediaBatchShareFlow.shareName(for: row("u1", filename: "")) == "u1.jpeg")
        #expect(
            MediaBatchShareFlow.shareName(for: row("u2", filename: "  ", mime: "video/quicktime"))
                == "u2.mov")
    }

    @Test("a name cannot climb out of its directory")
    func separatorsAreMadeHarmless() {
        #expect(
            MediaBatchShareFlow.shareName(for: row("u1", filename: "../../etc/passwd"))
                == ".._.._etc_passwd")
        let mixed = row("u1", filename: "a\\b:c.jpg")
        #expect(MediaBatchShareFlow.shareName(for: mixed) == "a_b_c.jpg")
        #expect(MediaBatchShareFlow.shareName(for: row("u1", filename: "..")) == "u1.jpeg")
        #expect(MediaBatchShareFlow.shareName(for: row("u1", filename: ".")) == "u1.jpeg")
        #expect(MediaBatchShareFlow.shareName(for: row("u1", filename: "a\u{0}b.jpg")) == "ab.jpg")
    }

    @Test("every chosen original arrives, renamed in place, and all are offered in one sheet")
    func oneSheetForEveryFile() async throws {
        let flow = MediaBatchShareFlow(remove: { _ in })
        let requests = Requests()
        let generation = Generation()
        let rows = [row("a1", filename: "first.jpg"), row("a2", filename: "")]
        let arriving = ["a1": try fetchedFile("a1.jpeg"), "a2": try fetchedFile("a2.jpeg")]

        let ran = await flow.share(rows, generation: { generation.value }) { file, rendition in
            requests.record(file, rendition)
            return try #require(arriving[file.uid])
        }

        #expect(ran)
        #expect(flow.lastError == nil)
        #expect(!flow.isSharing)
        let batch = try #require(flow.offered, "nothing was offered")
        #expect(batch.files.map(\.lastPathComponent) == ["first.jpg", "a2.jpeg"])
        // Renamed INSIDE the enclosure the fetch made, which is what a discard removes.
        #expect(
            batch.files[0].deletingLastPathComponent()
                == arriving["a1"]?.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: batch.files[0].path))
        #expect(BatchShareSheet.activityItems(for: batch.files) == batch.files)
        #expect(requests.asked.map { $0.uid } == ["a1", "a2"])
    }

    @Test("only the original is ever asked for, never a derived tier")
    func onlyTheOriginalIsAskedFor() async throws {
        let flow = MediaBatchShareFlow(remove: { _ in })
        let requests = Requests()
        let rows = [row("v1", filename: "clip.mov", mime: "video/quicktime")]
        let file = try fetchedFile("v1.mov")

        await flow.share(rows, generation: { 1 }) { attachment, rendition in
            requests.record(attachment, rendition)
            return file
        }

        #expect(requests.asked.count == 1)
        #expect(requests.asked.first?.rendition == .original)
    }

    @Test("a second tap while a batch is running starts no download and no second batch")
    func aSecondTapIsRefused() async throws {
        let flow = MediaBatchShareFlow(remove: { _ in })
        let requests = Requests()
        let rows = [row("a1", filename: "a.jpg")]
        let file = try fetchedFile("a1.jpeg")

        await flow.share(rows, generation: { 1 }) { attachment, rendition in
            requests.record(attachment, rendition)
            #expect(flow.isSharing, "the spinner is not up while the batch runs")
            let second = await flow.share(rows, generation: { 1 }) { attachment, rendition in
                requests.record(attachment, rendition)
                return file
            }
            #expect(!second, "a second batch was started over one already running")
            return file
        }

        #expect(requests.asked.count == 1)
        #expect(flow.offered?.files.count == 1)
    }

    @Test("another sign-in between two files drops the first and never asks for the second")
    func anIdentityChangeMidBatchDiscards() async throws {
        let removals = Removals()
        let flow = MediaBatchShareFlow(remove: { removals.record($0) })
        let requests = Requests()
        let generation = Generation()
        let rows = [row("a1", filename: "a.jpg"), row("a2", filename: "b.jpg")]
        let first = try fetchedFile("a1.jpeg")

        await flow.share(rows, generation: { generation.value }) { attachment, rendition in
            requests.record(attachment, rendition)
            // The first file arrives, and by then the session is somebody else's.
            generation.value = 8
            return first
        }

        #expect(requests.asked.map { $0.uid } == ["a1"], "the second file was asked for anyway")
        #expect(flow.offered == nil)
        #expect(!flow.isSharing)
        #expect(
            removals.all.map { $0.deletingLastPathComponent() }
                == [first.deletingLastPathComponent()],
            "the previous account's file was kept")
    }

    @Test("signing out mid-batch is an identity change too")
    func signingOutMidBatchDiscards() async throws {
        let removals = Removals()
        let flow = MediaBatchShareFlow(remove: { removals.record($0) })
        let requests = Requests()
        let generation = Generation()
        let rows = [row("a1", filename: "a.jpg"), row("a2", filename: "b.jpg")]
        let first = try fetchedFile("a1.jpeg")

        await flow.share(rows, generation: { generation.value }) { attachment, rendition in
            requests.record(attachment, rendition)
            generation.value = nil
            return first
        }

        #expect(requests.asked.count == 1)
        #expect(flow.offered == nil)
        #expect(removals.all.count == 1)
    }

    @Test("select mode ending mid-batch drops the files, asks for no more and never offers them")
    func anAbandonedBatchOffersNothing() async throws {
        let removals = Removals()
        let flow = MediaBatchShareFlow(remove: { removals.record($0) })
        let requests = Requests()
        let held = HeldDownload()
        let rows = [
            row("a1", filename: "a.jpg"), row("a2", filename: "b.jpg"), row("a3", filename: ""),
        ]
        let first = try fetchedFile("a1.jpeg")
        let second = try fetchedFile("a2.jpeg")
        let third = try fetchedFile("a3.jpeg")

        let batch = Task {
            await flow.share(rows, generation: { 1 }) { attachment, rendition in
                requests.record(attachment, rendition)
                switch attachment.uid {
                case "a1": return first
                // Answered at once, so a batch that wrongly carries on ends rather than hangs.
                case "a3": return third
                default: return await held.wait()
                }
            }
        }
        #expect(await held.parked(), "precondition: the second download is on its way")
        // Select mode closes while the second file is still on the wire.
        flow.abandon()
        #expect(!flow.isSharing, "the spinner outlived select mode")
        held.answer(second)
        _ = await batch.value

        // Opening select mode again finds nothing to present.
        #expect(flow.offered == nil, "a batch nobody wants offered its files")
        #expect(flow.lastError == nil)
        #expect(!flow.isSharing)
        #expect(requests.asked.map { $0.uid } == ["a1", "a2"], "the third file was asked for")
        #expect(
            Set(removals.all.map { $0.deletingLastPathComponent() })
                == [first.deletingLastPathComponent(), second.deletingLastPathComponent()],
            "the abandoned batch's files were kept")
    }

    @Test("a new batch after an abandoned one runs, and the old one waking late leaves it alone")
    func aNewBatchIsNotRefusedByTheOneItReplaced() async throws {
        let removals = Removals()
        let flow = MediaBatchShareFlow(remove: { removals.record($0) })
        let held = HeldDownload()
        let stale = try fetchedFile("a1.jpeg")
        let fresh = try fetchedFile("b1.jpeg")

        let old = Task {
            await flow.share([row("a1", filename: "")], generation: { 1 }) { _, _ in
                await held.wait()
            }
        }
        #expect(await held.parked(), "precondition: the old download is on its way")
        flow.abandon()

        let ran = await flow.share([row("b1", filename: "")], generation: { 1 }) { _, _ in fresh }
        #expect(ran, "the new batch was refused by the flag of the one it replaced")
        #expect(flow.offered?.files == [fresh])

        held.answer(stale)
        _ = await old.value

        #expect(flow.offered?.files == [fresh], "the old batch replaced the new batch's offer")
        #expect(!flow.isSharing)
        #expect(flow.lastError == nil)
        #expect(removals.all == [stale], "the old batch's file was kept, or the new one's dropped")
    }

    @Test("a download failing halfway says why, offers nothing and lets go of what arrived")
    func aFailureMidBatchReleasesWhatArrived() async throws {
        let removals = Removals()
        let flow = MediaBatchShareFlow(remove: { removals.record($0) })
        let rows = [row("a1", filename: "a.jpg"), row("a2", filename: "b.jpg")]
        let first = try fetchedFile("a1.jpeg")

        let ran = await flow.share(rows, generation: { 1 }) { attachment, _ in
            guard attachment.uid == "a1" else { throw OriginalMediaError.notSignedIn }
            return first
        }

        #expect(ran)
        #expect(flow.offered == nil)
        #expect(flow.lastError == OriginalMediaError.notSignedIn.errorDescription)
        #expect(!flow.isSharing)
        #expect(
            removals.all.map { $0.deletingLastPathComponent() }
                == [first.deletingLastPathComponent()],
            "the file that did arrive was kept after the batch failed")
    }

    @Test("nobody signed in when the batch starts asks for nothing and says why")
    func noSessionAsksForNothing() async {
        let flow = MediaBatchShareFlow(remove: { _ in })
        let requests = Requests()

        let ran = await flow.share([row("a1", filename: "a.jpg")], generation: { nil }) {
            attachment, rendition in
            requests.record(attachment, rendition)
            return URL(filePath: "/nonexistent")
        }

        #expect(ran)
        #expect(requests.asked.isEmpty)
        #expect(flow.offered == nil)
        #expect(flow.lastError == OriginalMediaError.notSignedIn.errorDescription)
    }

    @Test("an empty selection runs no batch")
    func anEmptySelectionRunsNothing() async {
        let flow = MediaBatchShareFlow(remove: { _ in })
        let requests = Requests()

        let ran = await flow.share([], generation: { 1 }) { attachment, rendition in
            requests.record(attachment, rendition)
            return URL(filePath: "/nonexistent")
        }

        #expect(!ran)
        #expect(requests.asked.isEmpty)
        #expect(flow.offered == nil)
    }

    @Test("a new batch lets go of the last batch's files and the sheet closing stops the offer")
    func aNewBatchReleasesTheLast() async throws {
        let removals = Removals()
        let flow = MediaBatchShareFlow(remove: { removals.record($0) })
        let firstFile = try fetchedFile("a1.jpeg")
        let secondFile = try fetchedFile("a2.jpeg")

        await flow.share([row("a1", filename: "")], generation: { 1 }) { _, _ in firstFile }
        flow.finish()
        #expect(flow.offered == nil)
        #expect(removals.all.isEmpty, "a dismissal deleted a file another app may still read")

        await flow.share([row("a2", filename: "")], generation: { 1 }) { _, _ in secondFile }

        #expect(removals.all == [firstFile])
        #expect(flow.offered?.files == [secondFile])
    }
}
