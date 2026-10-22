import Foundation
import MemosCore
import Testing
import UniformTypeIdentifiers

@testable import MemosFeatures

private func row(_ uid: String, filename: String, mime: String = "image/jpeg") -> LibraryRow {
    LibraryRow(
        attachment: MemoAttachment(
            uid: uid,
            mime: mime,
            status: .ready,
            previewURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/mobile"),
            webURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/web"),
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

    @Test("sharing N pictures asks for N mobile tiers and never an original (MEMNG-874)")
    func picturesAreSharedAsTheirMobileTier() async throws {
        let flow = MediaBatchShareFlow(remove: { _ in })
        let rows = (1...3).map { row("p\($0)", filename: "IMG_\($0).PNG", mime: "image/png") }
        var paths: [String] = []

        await flow.share(rows, generation: { 1 }) { attachment, rendition in
            // The URL the download lane will fetch is the one `file(_:)` resolves for the
            // rendition asked — the request itself, not merely the label on it.
            paths.append(attachment.file(rendition)?.url.path ?? "none")
            return try fetchedFile("\(attachment.uid).jpeg")
        }

        #expect(paths == ["p1", "p2", "p3"].map { "/api/attachments/\($0)/mobile" })
        #expect(!paths.contains { $0.hasSuffix("/o") })
        let batch = try #require(flow.offered, "nothing was offered")
        // The picture's own name, under the extension of the JPEG that arrived (MEMNG-836).
        #expect(batch.files.map(\.lastPathComponent) == ["IMG_1.jpeg", "IMG_2.jpeg", "IMG_3.jpeg"])
        // Every item, the camera PNGs included, is handed over as ONE type: a JPEG by its name.
        #expect(batch.files.allSatisfy { UTType(filenameExtension: $0.pathExtension) == .jpeg })
    }

    @Test("a completed share closes the sheet and keeps the files; a cancel leaves it to the sheet")
    func aCompletedShareClosesTheSheet() async throws {
        let removed = Removals()
        let flow = MediaBatchShareFlow(remove: { removed.record($0) })
        let file = try fetchedFile("a1.jpeg")
        await flow.share([row("a1", filename: "a.jpg")], generation: { 1 }) { _, _ in file }
        let batch = try #require(flow.offered, "nothing was offered")
        let controller = ShareSheet.controller(items: batch.files, onComplete: { flow.finish() })

        controller.completionWithItemsHandler?(nil, false, nil, nil)
        #expect(flow.offered != nil, "a cancel cleared the offer itself")
        controller.completionWithItemsHandler?(nil, true, nil, nil)
        #expect(flow.offered == nil, "a completed share left the sheet up")
        // MEMNG-210: closing stops the offer; the file stays where the share target reads it.
        #expect(removed.all.isEmpty)
        #expect(FileManager.default.fileExists(atPath: batch.files[0].path))
    }

    @Test("a clip in the selection is still handed on as its mp4, never its master")
    func aClipIsSharedAsItsMp4() async throws {
        let flow = MediaBatchShareFlow(remove: { _ in })
        let requests = Requests()
        let rows = [row("v1", filename: "clip.mov", mime: "video/quicktime")]
        var paths: [String] = []

        await flow.share(rows, generation: { 1 }) { attachment, rendition in
            requests.record(attachment, rendition)
            paths.append(attachment.file(rendition)?.url.path ?? "none")
            return try fetchedFile("v1.mp4")
        }

        #expect(requests.asked.count == 1)
        #expect(requests.asked.first?.rendition == .shared)
        #expect(paths == ["/api/attachments/v1/web"])
        #expect(flow.offered?.files.map(\.lastPathComponent) == ["clip.mp4"])
    }

    @Test("a shared file keeps its name, and takes the extension of the file that arrived")
    func theNameFollowsTheArrivedType() {
        let jpeg = URL(filePath: "/enclosure/u1.jpeg")
        // Already the arrived type, under another spelling of it: left alone.
        #expect(MediaBatchShareFlow.named("first.jpg", like: jpeg) == "first.jpg")
        #expect(MediaBatchShareFlow.named("Holiday 2026.HEIC", like: jpeg) == "Holiday 2026.jpeg")
        #expect(MediaBatchShareFlow.named("scan", like: jpeg) == "scan.jpeg")
        #expect(MediaBatchShareFlow.named("u2.mov", like: URL(filePath: "/e/u2.mp4")) == "u2.mp4")
        // A dot inside a name is not a type: only a suffix the system knows is replaced.
        #expect(MediaBatchShareFlow.named("beach.v2", like: jpeg) == "beach.v2.jpeg")
        #expect(MediaBatchShareFlow.named("a.jpeg.PNG", like: jpeg) == "a.jpeg.jpeg")
        // A file that arrived with no extension leaves the name as it was.
        #expect(MediaBatchShareFlow.named("a.png", like: URL(filePath: "/e/u3")) == "a.png")
    }

    @Test("pictures that convert to one name are offered under different ones, in selection order")
    func namesStayUniqueAfterConversion() async throws {
        let flow = MediaBatchShareFlow(remove: { _ in })
        let rows = [
            row("p1", filename: "IMG_0001.PNG", mime: "image/png"),
            row("p2", filename: "IMG_0001.HEIC", mime: "image/heic"),
            // The same name in another case is the same name to the Files app.
            row("p3", filename: "img_0001.JPEG"),
            // A name that is already what the second file was given takes a suffix of its own.
            row("p4", filename: "IMG_0001-2.jpeg"),
        ]

        await flow.share(rows, generation: { 1 }) { attachment, _ in
            try fetchedFile("\(attachment.uid).jpeg")
        }

        let batch = try #require(flow.offered, "nothing was offered")
        let names = batch.files.map(\.lastPathComponent)
        #expect(
            names == ["IMG_0001.jpeg", "IMG_0001-2.jpeg", "img_0001-3.JPEG", "IMG_0001-2-2.jpeg"]
        )
        #expect(Set(names.map { $0.lowercased() }).count == rows.count)
        #expect(batch.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("a name no earlier file holds is kept; a taken one takes the first free suffix")
    func aTakenNameTakesTheFirstFreeSuffix() {
        #expect(MediaBatchShareFlow.unique("a.jpeg", among: []) == "a.jpeg")
        #expect(MediaBatchShareFlow.unique("a.jpeg", among: ["b.jpeg"]) == "a.jpeg")
        #expect(MediaBatchShareFlow.unique("a.jpeg", among: ["a.jpeg", "a-2.jpeg"]) == "a-3.jpeg")
        #expect(MediaBatchShareFlow.unique("A.JPEG", among: ["a.jpeg"]) == "A-2.JPEG")
        #expect(MediaBatchShareFlow.unique("scan", among: ["scan"]) == "scan-2")
        let dotted = MediaBatchShareFlow.unique("beach.v2.jpeg", among: ["beach.v2.jpeg"])
        #expect(dotted == "beach.v2-2.jpeg")
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
