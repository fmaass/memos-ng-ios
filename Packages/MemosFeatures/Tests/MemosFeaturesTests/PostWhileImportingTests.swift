import Foundation
import MemosOutbox
import Testing

@testable import MemosFeatures

/// A load that answers only when the test says so — or never.
private actor HeldLoad {
    private var answer: ComposePickerAnswer?
    private var waiters: [CheckedContinuation<ComposePickerAnswer, Never>] = []
    private(set) var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async -> ComposePickerAnswer {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        if let answer { return answer }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func answer(_ value: ComposePickerAnswer) {
        answer = value
        for waiter in waiters { waiter.resume(returning: value) }
        waiters = []
    }
}

/// What the queue was asked, in order.
@MainActor
private final class QueueLog {
    var staged: [UUID] = []
    var appended: [String] = []
    var released: [UUID] = []
}

/// Post while photos load (MEMNG-951): the sheet closes on what has arrived, and what has not
/// follows the capture into the queue on a task the sheet does not own.
@MainActor
@Suite("Post while importing")
struct PostWhileImportingTests {
    private static func media(_ name: String) -> PickedMedia {
        PickedMedia(url: URL(filePath: "/tmp/\(name)"), filename: name, mime: "image/heic")
    }

    /// Two items picked: the first arrives, the second is held by `second`.
    private func picked(
        second: HeldLoad
    ) async -> (imports: ComposeImports, loading: Task<Bool, Never>) {
        let imports = ComposeImports()
        let stamp = imports.selected()
        let loading = Task {
            await imports.load(["a", "b"], stamp: stamp) { item in
                if item == "a" { return .file(Self.media("a.heic")) }
                return await second.load()
            }
        }
        await second.waitUntilStarted()
        return (imports, loading)
    }

    @Test("with one item still loading, Post is enabled and the capture is written within a second")
    func postIsEnabledAndReturnsWhileAnItemLoads() async throws {
        let second = HeldLoad()
        let (imports, loading) = await picked(second: second)
        defer { loading.cancel() }
        #expect(imports.isImporting)
        // The rule before this ticket: the button was grey for as long as anything loaded.
        #expect(!imports.mayPost(text: "beach", existing: 0, whileImporting: false))
        #expect(imports.mayPost(text: "beach", existing: 0, whileImporting: true))
        // An item still loading is something to post even with no words.
        #expect(imports.mayPost(text: "", existing: 0, whileImporting: true))
        #expect(imports.beginPostAttempt(loadingGoesLater: true) == nil)
        #expect(imports.beginPostAttempt(loadingGoesLater: false) != nil)

        let log = QueueLog()
        let job = UUID()
        let arriving = try #require(ComposeArrivals(imports))
        #expect(arriving.ids.count == 1)
        let clock = ContinuousClock()
        let started = clock.now
        let result = await ComposeArrivals.stageThenFollow(
            arriving,
            stage: {
                log.staged.append(job)
                return job
            },
            append: { _, media in
                log.appended.append(media.filename)
                return true
            },
            release: { log.released.append($0) }
        )
        // The sheet closes on this answer, and the second item has still not arrived.
        #expect(clock.now - started < .seconds(1))
        #expect(result.written)
        #expect(log.staged == [job])
        #expect(log.released.isEmpty, "the capture was let go before its last file landed")

        await second.answer(.file(Self.media("b.heic")))
        let outcome = await result.follower?.value
        #expect(outcome == ComposeHandOff(delivered: 1, failed: 0, abandoned: 0))
        #expect(log.appended == ["b.heic"])
        #expect(log.released == [job])
    }

    @Test("nothing loading is nothing to follow: the capture is written and that is all")
    func nothingLoadingNoFollower() async {
        let imports = ComposeImports()
        imports.captured(Self.media("a.heic"))
        #expect(ComposeArrivals(imports) == nil)
        let result = await ComposeArrivals.stageThenFollow(
            nil, stage: { UUID() }, append: { _, _ in true }, release: { _ in })
        #expect(result.written)
        #expect(result.follower == nil)
    }

    @Test("a capture the queue refused is not followed, and its loads are not appended anywhere")
    func refusedCaptureIsNotFollowed() async throws {
        let second = HeldLoad()
        let (imports, loading) = await picked(second: second)
        defer { loading.cancel() }
        let log = QueueLog()
        let arriving = try #require(ComposeArrivals(imports))
        let result = await ComposeArrivals.stageThenFollow(
            arriving,
            stage: { nil },
            append: { _, media in
                log.appended.append(media.filename)
                return true
            },
            release: { log.released.append($0) }
        )
        #expect(!result.written)
        #expect(result.follower == nil)
        #expect(log.released.isEmpty)
    }

    @Test("a late file that fails loses nothing already sent and still lets the capture go")
    func failedLateFileStillReleases() async throws {
        let second = HeldLoad()
        let (imports, loading) = await picked(second: second)
        defer { loading.cancel() }
        let log = QueueLog()
        let job = UUID()
        let arriving = try #require(ComposeArrivals(imports))
        let result = await ComposeArrivals.stageThenFollow(
            arriving,
            stage: { job },
            append: { _, media in
                log.appended.append(media.filename)
                return true
            },
            release: { log.released.append($0) }
        )
        await second.answer(.failed(.unknown))
        let outcome = await result.follower?.value
        #expect(outcome == ComposeHandOff(delivered: 0, failed: 1, abandoned: 0))
        #expect(log.appended.isEmpty)
        #expect(log.released == [job])
        // The file that had arrived is still attached; the one that failed is marked, not gone.
        #expect(imports.attachments.map(\.filename) == ["a.heic"])
        #expect(imports.failed == 1)
    }

    @Test("a load that never answers does not keep the capture back past the limit")
    func neverAnsweringLoadIsReleasedAtTheLimit() async throws {
        let second = HeldLoad()
        let (imports, loading) = await picked(second: second)
        defer { loading.cancel() }
        let log = QueueLog()
        let job = UUID()
        let arriving = try #require(ComposeArrivals(imports))
        let result = await ComposeArrivals.stageThenFollow(
            arriving,
            within: .milliseconds(50),
            stage: { job },
            append: { _, media in
                log.appended.append(media.filename)
                return true
            },
            release: { log.released.append($0) }
        )
        let outcome = await result.follower?.value
        #expect(outcome == ComposeHandOff(delivered: 0, failed: 0, abandoned: 1))
        #expect(log.released == [job])
        // Arriving after the capture was let go, it is not appended to it.
        await second.answer(.file(Self.media("b.heic")))
        _ = await loading.value
        #expect(log.appended.isEmpty)
    }

    @Test("the pending-card switch is on unless the pane says off")
    func flagDefaultsOn() throws {
        let name = "pending-card.flag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        #expect(PendingCardFlag.isEnabled(defaults))
        defaults.set(false, forKey: PendingCardFlag.toggleKey)
        #expect(!PendingCardFlag.isEnabled(defaults))
    }
}

/// Every action a memo card has, on a pending card: applied to the capture, or disabled with the
/// reason (MEMNG-951).
@Suite("Pending memo card actions")
struct PendingMemoActionTests {
    private func job(_ change: (inout UploadJob) -> Void = { _ in }) -> UploadJob {
        var job = UploadJob(
            content: "x", capturedAt: Date(), files: [],
            binding: AccountBinding(
                serverBaseURL: URL(filePath: "/server"), ownerSubject: "fabian"))
        change(&job)
        return job
    }

    private func reason(_ action: PendingMemoAction, _ job: UploadJob) -> String?? {
        PendingMemoActions.offers(for: job).first { $0.action == action }.map(\.disabledReason)
    }

    @Test("every action is listed, and each one not applied says why")
    func everyActionIsOfferedOrExplained() {
        let offers = PendingMemoActions.offers(for: job())
        #expect(offers.map(\.action) == PendingMemoAction.allCases)
        for offer in offers where offer.action != .edit && offer.action != .remove {
            #expect(offer.disabledReason?.isEmpty == false, "\(offer.action) is silently inert")
        }
        #expect(reason(.edit, job()) == .some(nil))
        #expect(reason(.remove, job()) == .some(nil))
    }

    @Test("Edit waits for files still arriving and for a change on the wire")
    func editIsHeldWhileItWouldLoseSomething() {
        let arriving = job { $0.stagingLaunch = UUID() }
        #expect(reason(.edit, arriving) == .some(PendingMemoActions.stillArriving))
        #expect(
            reason(.edit, job { $0.editUnansweredSince = Date() })
                == .some(PendingMemoActions.editOnTheWire))
    }

    @Test("Remove is disabled once the server may hold the memo")
    func removeIsHeldOnceTheCreateMayHaveGone() {
        let creating = job { $0.state = .creating }
        #expect(reason(.remove, creating) == .some(PendingMemoActions.mayBeOnServer))
    }
}
