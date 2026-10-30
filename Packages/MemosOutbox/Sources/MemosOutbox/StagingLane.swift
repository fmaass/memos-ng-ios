import Foundation

/// Whether the photo library may be read.
public enum PhotoLibraryAccess: Sendable, Equatable {
    /// Every item may be read (`.authorized`), or the items the person shared with the app
    /// (`.limited`) — an item outside that set answers `PhotoLibraryCopyError.unavailable`.
    case granted
    /// Denied or restricted: nothing may be read until the person allows it in Settings.
    case denied
}

/// Why an item could not be copied out of the library.
public enum PhotoLibraryCopyError: Error, Equatable {
    /// The library does not hand this item over: not in a limited selection, or deleted.
    case unavailable
}

/// What the library said about an item it copied out.
public struct PhotoLibraryCopy: Sendable, Equatable {
    public var filename: String
    public var mime: String
    public var lastModified: Date?

    public init(filename: String, mime: String, lastModified: Date? = nil) {
        self.filename = filename
        self.mime = mime
        self.lastModified = lastModified
    }
}

/// The photo library the `StagingLane` copies from. Behind a protocol so the lane is driven in
/// tests without a library; the app hands it `PhotoKitLibrary`.
public protocol PhotoLibrarySource: Sendable {
    /// The access the library grants now. `mayPrompt` asks the person when nobody has yet — the
    /// one prompt the system shows (it never asks twice) — and is false wherever no person can
    /// answer, such as a background task.
    func access(mayPrompt: Bool) async -> PhotoLibraryAccess
    /// Writes the item's original bytes to `destination`, which does not exist yet. Throws
    /// `PhotoLibraryCopyError.unavailable` for an item the library will not hand over, and
    /// `CancellationError` when the task is cancelled mid-copy.
    func copy(_ assetIdentifier: String, to destination: URL) async throws -> PhotoLibraryCopy
}

/// What one staging pass came to.
public struct StagingPass: Sendable, Equatable {
    /// Items that became files of their capture.
    public var staged = 0
    /// Items left in staging because Photos would not hand them over.
    public var needsAccess = 0
    /// Items left in staging by a copy that failed for another reason; the next pass retries.
    public var failed = 0
    /// Whether the pass was told to stop before every item had been tried.
    public var stopped = false

    public init(staged: Int = 0, needsAccess: Int = 0, failed: Int = 0, stopped: Bool = false) {
        self.staged = staged
        self.needsAccess = needsAccess
        self.failed = failed
        self.stopped = stopped
    }
}

/// Copies every capture's items still in Photos into the group container (MEMNG-952): the
/// library's bytes to a fixed temporary file beside the capture's files, then the rename and the
/// manifest write as one mutation (`OutboxRepository.commitStaged`), after which the planners see
/// an ordinary file.
///
/// One pass at a time: a pass asked for while another runs JOINS it rather than starting a second
/// one, so two passes never write the same temporary file. A pass told to `stop` — a background
/// task's expiry — cancels the copy in flight, deletes what it wrote, and leaves every item it has
/// not committed in staging for the next pass.
public actor StagingLane {
    private let repository: OutboxRepository
    private let library: any PhotoLibrarySource
    private let onChange: @Sendable () async -> Void
    private var running: Task<StagingPass, Never>?
    private var stopRequested = false
    private var stopWhen: @Sendable () -> Bool = { false }

    public init(
        repository: OutboxRepository,
        library: any PhotoLibrarySource,
        onChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.library = library
        self.onChange = onChange
    }

    /// Runs a pass over every capture, or joins the one already running. `stopWhen` is asked
    /// before each item as well as `stop()`, so a stop that lands before this pass has started
    /// is not lost.
    @discardableResult
    public func drain(
        mayPrompt: Bool, stopWhen: @escaping @Sendable () -> Bool = { false }
    ) async -> StagingPass {
        if let running { return await running.value }
        stopRequested = false
        self.stopWhen = stopWhen
        let pass = Task { await self.pass(mayPrompt: mayPrompt) }
        running = pass
        let outcome = await pass.value
        running = nil
        return outcome
    }

    /// Ends the running pass at the next item, cancelling the copy in flight. A pass started after
    /// this runs normally.
    public func stop() {
        stopRequested = true
        running?.cancel()
    }

    /// Whether any capture still holds an item in Photos the lane can try: what a background task
    /// is scheduled for.
    public func hasWork() async -> Bool {
        let jobs = (try? await repository.loadJobs()) ?? []
        return jobs.contains { $0.cancelledAt == nil && !$0.stagingFiles.isEmpty }
    }

    private var shouldStop: Bool { stopRequested || Task.isCancelled || stopWhen() }

    private func pass(mayPrompt: Bool) async -> StagingPass {
        var outcome = StagingPass()
        let jobs = ((try? await repository.loadJobs()) ?? []).filter {
            $0.cancelledAt == nil && !$0.stagingFiles.isEmpty
        }
        guard !jobs.isEmpty else { return outcome }
        let access = await library.access(mayPrompt: mayPrompt)
        for job in jobs {
            guard access == .granted else {
                // Nothing is copied, and every item says why; the files already here go meanwhile.
                if (try? await repository.markStaging(
                    job.stagingFiles, of: job.id, needsPhotosAccess: true)) != nil
                {
                    await onChange()
                }
                outcome.needsAccess += job.stagingFiles.count
                continue
            }
            for item in job.stagingFiles {
                if shouldStop {
                    outcome.stopped = true
                    return outcome
                }
                switch await stage(item, of: job.id) {
                case .staged: outcome.staged += 1
                case .unavailable: outcome.needsAccess += 1
                case .failed: outcome.failed += 1
                case .stopped:
                    outcome.stopped = true
                    return outcome
                }
            }
        }
        return outcome
    }

    private enum ItemOutcome { case staged, unavailable, failed, stopped }

    private func stage(_ item: StagingFile, of jobID: UUID) async -> ItemOutcome {
        let temporary = repository.stagingTemporaryURL(jobID: jobID, item: item)
        // What a terminated run left half-written is never the start of this copy.
        try? FileManager.default.removeItem(at: temporary)
        let copied: PhotoLibraryCopy
        do {
            copied = try await library.copy(item.assetIdentifier, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if error is CancellationError || shouldStop { return .stopped }
            if case PhotoLibraryCopyError.unavailable = error {
                if (try? await repository.markStaging(
                    [item], of: jobID, needsPhotosAccess: true)) != nil
                {
                    await onChange()
                }
                return .unavailable
            }
            return .failed
        }
        // The bytes are all here: committed even when a stop arrived meanwhile, so the work is
        // not thrown away; the stop is honoured before the next item.
        let committed = try? await repository.commitStaged(
            item, of: jobID, copiedTo: temporary, filename: copied.filename, mime: copied.mime,
            lastModified: copied.lastModified)
        switch committed {
        case .staged:
            await onChange()
            return .staged
        case .notStaging:
            return .failed
        case nil:
            try? FileManager.default.removeItem(at: temporary)
            return .failed
        }
    }
}

/// A system background task as the staging handler sees it: `BGProcessingTask` in the app.
@MainActor
public protocol StagingBackgroundTask: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension StagingLane {
    /// The `BGProcessingTask` handler: drains every capture's items still in Photos, and on the
    /// task's expiry stops cleanly, leaving every item it has not committed in staging. The system
    /// is told exactly once, whichever of the two arrives first (`BackgroundRun`).
    ///
    /// Called on the main actor, where the app's registration delivers the task.
    @MainActor
    @discardableResult
    public static func run(
        _ task: some StagingBackgroundTask, on lane: StagingLane,
        then finished: @escaping @MainActor (StagingPass) async -> Void = { _ in }
    ) -> Task<Void, Never> {
        let run = BackgroundRun()
        task.expirationHandler = { [weak task] in
            run.expire()
            Task { await lane.stop() }
            if run.claimCompletion() { task?.setTaskCompleted(success: false) }
        }
        let work = Task { @MainActor in
            let pass = await lane.drain(mayPrompt: false, stopWhen: { run.isFinished })
            await finished(pass)
            if run.claimCompletion() { task.setTaskCompleted(success: !pass.stopped) }
        }
        run.attach(work)
        return work
    }
}
