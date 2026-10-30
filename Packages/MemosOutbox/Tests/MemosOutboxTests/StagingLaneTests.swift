import Foundation
import MemosOutbox
import Testing

/// A photo library with no Photos in it: each item's bytes are a fixed function of its
/// identifier, and every copy is counted.
private actor FakeLibrary: PhotoLibrarySource {
    var granted: Bool
    private(set) var copies: [String] = []
    private var unavailable: Set<String> = []
    private var heldItem: String?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldStarted = false

    init(granted: Bool = true) { self.granted = granted }

    static func bytes(_ identifier: String) -> Data { Data("bytes of \(identifier)".utf8) }

    func access(mayPrompt: Bool) async -> PhotoLibraryAccess { granted ? .granted : .denied }

    func makeUnavailable(_ identifier: String) { unavailable.insert(identifier) }

    /// The copy of `identifier` parks after writing until `release()`.
    func hold(_ identifier: String) { heldItem = identifier }

    func waitUntilHeld() async {
        if heldStarted { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        heldItem = nil
        for waiter in heldWaiters { waiter.resume() }
        heldWaiters = []
    }

    func copy(_ assetIdentifier: String, to destination: URL) async throws -> PhotoLibraryCopy {
        copies.append(assetIdentifier)
        guard !unavailable.contains(assetIdentifier) else {
            throw PhotoLibraryCopyError.unavailable
        }
        try Self.bytes(assetIdentifier).write(to: destination)
        if heldItem == assetIdentifier {
            heldStarted = true
            for waiter in startedWaiters { waiter.resume() }
            startedWaiters = []
            await withCheckedContinuation { heldWaiters.append($0) }
        }
        return PhotoLibraryCopy(filename: "\(assetIdentifier).heic", mime: "image/heic")
    }
}

/// The system's background task, as the staging handler drives it.
@MainActor
private final class FakeTask: StagingBackgroundTask {
    var expirationHandler: (() -> Void)?
    private(set) var completions: [Bool] = []

    func setTaskCompleted(success: Bool) { completions.append(success) }
}

/// The lane that copies picked items from Photos into their capture (MEMNG-952). Every case
/// drives the real repository on a real directory; only the library is a double.
@MainActor
@Suite("Items still in Photos are staged into their capture")
struct StagingLaneTests {
    private struct Rig {
        let root: URL
        let repository: OutboxRepository
        let library: FakeLibrary
        let lane: StagingLane

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        func capture(
            _ identifiers: [String], loaded: [String] = [], content: String = "lake"
        ) async throws -> UploadJob {
            let sources = try loaded.map { name in
                StagedSource(
                    url: try Fixture.file(in: root, named: name, bytes: 64), filename: name,
                    mime: "image/heic")
            }
            return try await repository.enqueue(
                content: content, visibility: "PRIVATE", capturedAt: Date(),
                binding: Fixture.binding(), sources: sources,
                staging: identifiers.map { StagingFile(assetIdentifier: $0) })
        }

        func mediaNames(_ job: UploadJob) throws -> [String] {
            let directory = repository.stagingTemporaryURL(
                jobID: job.id, item: StagingFile(assetIdentifier: "x")
            ).deletingLastPathComponent()
            return try FileManager.default.contentsOfDirectory(atPath: directory.path()).sorted()
        }
    }

    private func rig(granted: Bool = true) throws -> Rig {
        let root = try Fixture.temporaryDirectory()
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        let library = FakeLibrary(granted: granted)
        return Rig(
            root: root, repository: repository, library: library,
            lane: StagingLane(repository: repository, library: library))
    }

    // MARK: - denied access

    @Test("denied access: the loaded file uploads, the rest carry the reason and Open Settings")
    func deniedAccessLoadedFilesGo() async throws {
        let rig = try rig(granted: false)
        defer { rig.cleanUp() }
        let job = try await rig.capture(["p1", "p2"], loaded: ["here.heic"])

        let pass = await rig.lane.drain(mayPrompt: true)
        #expect(pass == StagingPass(needsAccess: 2))
        #expect(await rig.library.copies.isEmpty, "nothing is read without access")

        let after = try #require(await rig.repository.job(job.id))
        #expect(after.stagingFiles.map(\.needsPhotosAccess) == [true, true])
        #expect(after.state != .held, "the capture is not stopped: its loaded file goes")
        // The file already here goes now; the create waits for the rest.
        let action = OutboxPlanner.nextWholeAction(
            for: after, credentials: Fixture.credentials(), now: Date(), schedulingOpen: true)
        #expect(action == .upload(starting: after.files.map(\.id)))
        #expect(after.files.map(\.filename) == ["here.heic"])

        let rows = try #require(TransferLedger.project(after, now: Date())).files
        #expect(rows.count == 3)
        let photoReasons = rows.dropFirst().map(\.reason)
        #expect(photoReasons == [.inPhotos(needsAccess: true), .inPhotos(needsAccess: true)])

        // Allowed later in Settings: the next pass copies them and clears the mark.
        await rig.library.setGranted()
        let again = await rig.lane.drain(mayPrompt: false)
        #expect(again.staged == 2)
        let staged = try #require(await rig.repository.job(job.id))
        #expect(staged.staging == nil)
        #expect(staged.files.count == 3)
    }

    @Test("an item outside a limited selection waits for access; the others are copied")
    func unavailableItemNeedsAccess() async throws {
        let rig = try rig()
        defer { rig.cleanUp() }
        await rig.library.makeUnavailable("gone")
        let job = try await rig.capture(["p1", "gone"])
        let pass = await rig.lane.drain(mayPrompt: false)
        #expect(pass == StagingPass(staged: 1, needsAccess: 1))
        let after = try #require(await rig.repository.job(job.id))
        #expect(after.stagingFiles.map(\.assetIdentifier) == ["gone"])
        #expect(after.stagingFiles.first?.needsPhotosAccess == true)
        #expect(after.stillArriving, "the create waits for the item still in Photos")
    }

    // MARK: - termination mid-copy

    @Test("a copy cut off by termination resumes on the next launch without a duplicate file")
    func interruptedCopyResumes() async throws {
        let rig = try rig()
        defer { rig.cleanUp() }
        let job = try await rig.capture(["p1", "p2"])
        let first = try #require(job.staging?.first)
        let second = try #require(job.staging?.last)
        // The crashed run: half of p1's bytes in its temporary file, and — for p2 — a rename that
        // landed before the manifest write did. The manifest still has both in staging.
        let partial = rig.repository.stagingTemporaryURL(jobID: job.id, item: first)
        try Data("byt".utf8).write(to: partial)
        let renamed = partial.deletingLastPathComponent()
            .appending(path: "\(second.id.uuidString).heic")
        try FakeLibrary.bytes("p2").write(to: renamed)

        // The next launch: a new repository over the same container, and a lane on it.
        let relaunched = try OutboxRepository(root: rig.root.appending(path: "outbox"))
        let lane = StagingLane(repository: relaunched, library: rig.library)
        let pass = await lane.drain(mayPrompt: false)
        #expect(pass == StagingPass(staged: 2))

        let after = try #require(await relaunched.job(job.id))
        #expect(after.staging == nil)
        #expect(after.files.map(\.id) == [first.id, second.id])
        for (file, identifier) in zip(after.files, ["p1", "p2"]) {
            let stored = relaunched.mediaURL(job: after, file: file)
            #expect(try Data(contentsOf: stored) == FakeLibrary.bytes(identifier))
            #expect(file.byteSize == Int64(FakeLibrary.bytes(identifier).count))
        }
        // One file per item on disk, and no temporary file left.
        let expected = ["\(first.id.uuidString).heic", "\(second.id.uuidString).heic"].sorted()
        #expect(try rig.mediaNames(after) == expected)

        // A pass after that finds nothing to copy.
        #expect(await lane.drain(mayPrompt: false) == StagingPass())
        #expect(await rig.library.copies == ["p1", "p2"])
    }

    @Test("a second commit of an item already staged is refused and its copy removed")
    func secondCommitRefused() async throws {
        let rig = try rig()
        defer { rig.cleanUp() }
        let job = try await rig.capture(["p1"])
        let item = try #require(job.staging?.first)
        let temporary = rig.repository.stagingTemporaryURL(jobID: job.id, item: item)
        try FakeLibrary.bytes("p1").write(to: temporary)
        let first = try await rig.repository.commitStaged(
            item, of: job.id, copiedTo: temporary, filename: "p1.heic", mime: "image/heic",
            lastModified: nil)
        guard case .staged(let staged) = first else {
            Issue.record("the first commit was refused: \(first)")
            return
        }
        #expect(staged.files.map(\.id) == [item.id])
        try FakeLibrary.bytes("p1").write(to: temporary)
        let second = try await rig.repository.commitStaged(
            item, of: job.id, copiedTo: temporary, filename: "p1.heic", mime: "image/heic",
            lastModified: nil)
        #expect(second == .notStaging)
        #expect(!FileManager.default.fileExists(atPath: temporary.path()))
        #expect(await rig.repository.job(job.id)?.files.count == 1)
    }

    @Test("two passes asked for at once are one pass: every item is copied once")
    func overlappingDrainsJoin() async throws {
        let rig = try rig()
        defer { rig.cleanUp() }
        let job = try await rig.capture(["p1", "p2", "p3"])
        async let one = rig.lane.drain(mayPrompt: false)
        async let two = rig.lane.drain(mayPrompt: false)
        let passes = await [one, two]
        #expect(passes.map(\.staged) == [3, 3])
        #expect(await rig.library.copies == ["p1", "p2", "p3"])
        #expect(await rig.repository.job(job.id)?.files.count == 3)
    }

    @Test("a capture with only items in Photos is not removed as empty when its editor lets go")
    func releaseKeepsAPhotosOnlyCapture() async throws {
        let rig = try rig()
        defer { rig.cleanUp() }
        let launch = UUID()
        let job = try await rig.repository.enqueue(
            content: "", visibility: nil, capturedAt: Date(), binding: Fixture.binding(),
            sources: [], stagingLaunch: launch,
            staging: [StagingFile(assetIdentifier: "p1")])
        let release = try await rig.repository.releaseStaging(job.id, arrivingFrom: launch)
        #expect(release == .released)
        #expect(await rig.repository.job(job.id)?.stagingFiles.count == 1)
    }

    // MARK: - the background task

    @Test("driven by the task's handler, the lane drains every staging file and completes once")
    func backgroundTaskDrainsEverything() async throws {
        let rig = try rig()
        defer { rig.cleanUp() }
        let one = try await rig.capture(["p1", "p2"])
        let two = try await rig.capture(["p3"], content: "hill")
        let task = FakeTask()
        await StagingLane.run(task, on: rig.lane).value
        #expect(task.completions == [true])
        for id in [one.id, two.id] {
            let after = try #require(await rig.repository.job(id))
            #expect(after.staging == nil)
        }
        #expect(await rig.repository.job(one.id)?.files.count == 2)
        #expect(await rig.repository.job(two.id)?.files.count == 1)
        #expect(!(await rig.lane.hasWork()))
    }

    @Test(
        "on expiry the lane stops cleanly, leaving the untouched files in staging",
        .timeLimit(.minutes(1)))
    func backgroundTaskExpiry() async throws {
        let rig = try rig()
        defer { rig.cleanUp() }
        let job = try await rig.capture(["p1", "p2", "p3"])
        await rig.library.hold("p2")
        let task = FakeTask()
        let work = StagingLane.run(task, on: rig.lane)
        await rig.library.waitUntilHeld()
        task.expirationHandler?()
        #expect(task.completions == [false], "the system is told at the expiry")
        await rig.library.release()
        await work.value
        #expect(task.completions == [false], "and only once")

        let after = try #require(await rig.repository.job(job.id))
        // The copy in flight had all its bytes and is kept; the one after it was never begun.
        #expect(after.files.map(\.filename) == ["p1.heic", "p2.heic"])
        #expect(after.stagingFiles.map(\.assetIdentifier) == ["p3"])
        #expect(after.stagingFiles.first?.needsPhotosAccess == nil)
        #expect(await rig.library.copies == ["p1", "p2"])
        let untouched = try #require(after.staging?.first)
        let temporary = rig.repository.stagingTemporaryURL(jobID: job.id, item: untouched)
        #expect(!FileManager.default.fileExists(atPath: temporary.path()))
        #expect(await rig.lane.hasWork())
    }
}

extension FakeLibrary {
    fileprivate func setGranted() { granted = true }
}
