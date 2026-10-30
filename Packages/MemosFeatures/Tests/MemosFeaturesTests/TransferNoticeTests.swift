import Foundation
import MemosCore
import MemosOutbox
import Testing

@testable import MemosFeatures

nonisolated private let start = Date(timeIntervalSince1970: 1_760_000_000)
nonisolated private let server = URL(string: "https://memos.example.invalid")!

private func files(_ count: Int, done: Int) -> [OutboxFile] {
    (0..<count).map { index in
        OutboxFile(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            relativePath: "\(index).heic", filename: "\(index).heic", mime: "image/heic",
            byteSize: 100, uploadUID: index < done ? "upload-\(index)" : nil,
            bytesConfirmed: index < done ? 100 : 0)
    }
}

private func capture(
    _ state: JobState, id: UUID = UUID(), hold: HoldReason? = nil, files: [OutboxFile]
) -> UploadJob {
    var job = UploadJob(
        content: "Day at the lake", capturedAt: start, files: files,
        binding: AccountBinding(serverBaseURL: server, ownerSubject: "alice"),
        state: state, holdReason: hold)
    job.id = id
    return job
}

/// A fresh suite, removed when the test is done.
private struct NoticeDefaults {
    let name = "transfer.notices.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func forget() { UserDefaults.standard.removePersistentDomain(forName: name) }
}

/// The ledger, applied read after read as the outbox applies them.
@MainActor
private final class ScriptedLedger {
    let ledger = TransferLedger(clock: { start })
    private var generation = 0

    func read(_ manifests: [UploadJob]) -> [TransferJob] {
        generation += 1
        ledger.apply(manifests, generation: generation)
        return ledger.jobs
    }
}

@MainActor
@Suite("Transfer notices: one per memo, one per hold")
struct TransferNoticeTests {
    @Test("a 30-file capture announces once, live, when it becomes a memo")
    func thirtyFilesOneLive() {
        let suite = NoticeDefaults()
        defer { suite.forget() }
        let notifier = TransferNotifier(defaults: suite.defaults)
        let script = ScriptedLedger()
        let id = UUID()
        var posted: [TransferNotice] = []
        for done in 0...30 {
            let jobs = script.read([capture(.uploading, id: id, files: files(30, done: done))])
            posted += notifier.observe(jobs: jobs, resolved: [:], frontmost: false, now: start)
        }
        let creating = script.read([capture(.creating, id: id, files: files(30, done: 30))])
        posted += notifier.observe(jobs: creating, resolved: [:], frontmost: false, now: start)
        let gone = script.read([])
        posted += notifier.observe(
            jobs: gone, resolved: [id: "memo-1"], frontmost: false, now: start)
        // The same transition delivered again, as a second read would.
        posted += notifier.observe(
            jobs: gone, resolved: [id: "memo-1"], frontmost: false, now: start)
        #expect(posted.count == 1)
        #expect(posted.first?.kind == .live)
        #expect(posted.first?.title == "Day at the lake is live")
        #expect(posted.first?.route == .memo(uid: "memo-1"))
    }

    @Test("a held capture's notice says the row's reason, byte for byte, and its one action")
    func heldSaysTheLedgerReason() throws {
        let suite = NoticeDefaults()
        defer { suite.forget() }
        let notifier = TransferNotifier(defaults: suite.defaults)
        let script = ScriptedLedger()
        let held = capture(.held, hold: .tooLarge, files: files(3, done: 1))
        let jobs = script.read([held])
        let row = try #require(
            TransfersPresentation.sections(
                for: script.ledger, now: start, lastProgressAt: [:], verdict: .permitted
            ).first?.rows.first)
        let posted = notifier.observe(jobs: jobs, resolved: [:], frontmost: false, now: start)
        let again = notifier.observe(
            jobs: script.read([held]), resolved: [:], frontmost: false, now: start)
        #expect(posted.count == 1, "one per capture, never one per file")
        #expect(again.isEmpty)
        let notice = try #require(posted.first)
        #expect(notice.kind == .held)
        let reason = try #require(row.reason)
        #expect(Array(notice.body.utf8) == Array(reason.utf8))
        #expect(
            notice.body == "Too large for the server — remove it, or try again if the limit rises")
        #expect(notice.subtitle == (row.action?.title ?? ""))
        #expect(notice.title == "Day at the lake didn't upload")
        #expect(notice.route == .transfers(jobID: held.id))
    }

    @Test("nothing is posted while frontmost, and what was seen then is not posted later")
    func frontmostPostsNothing() {
        let suite = NoticeDefaults()
        defer { suite.forget() }
        let notifier = TransferNotifier(defaults: suite.defaults)
        let script = ScriptedLedger()
        let held = capture(.held, hold: .serverRefused, files: files(2, done: 0))
        let jobs = script.read([held])
        let landed = UUID()
        #expect(
            notifier.observe(jobs: jobs, resolved: [landed: "m"], frontmost: true, now: start)
                .isEmpty)
        #expect(
            notifier.observe(jobs: jobs, resolved: [landed: "m"], frontmost: false, now: start)
                .isEmpty)
    }

    @Test("a relaunch reading the same hold posts nothing; a claim goes with its capture")
    func claimsSurviveRelaunch() {
        let suite = NoticeDefaults()
        defer { suite.forget() }
        let script = ScriptedLedger()
        let held = capture(.held, hold: .signInRequired, files: files(1, done: 0))
        let jobs = script.read([held])
        let first = TransferNotifier(defaults: suite.defaults)
        #expect(first.observe(jobs: jobs, resolved: [:], frontmost: false, now: start).count == 1)
        let relaunched = TransferNotifier(defaults: suite.defaults)
        #expect(relaunched.observe(jobs: jobs, resolved: [:], frontmost: false, now: start).isEmpty)
        _ = relaunched.observe(jobs: script.read([]), resolved: [:], frontmost: false, now: start)
        #expect(
            (suite.defaults.stringArray(forKey: TransferNotifier.claimsKey) ?? []).isEmpty,
            "a capture that has left the queue keeps no claim")
    }

    @Test("a notice's route survives the system's userInfo and maps onto the app's navigation")
    func routeMapping() throws {
        let jobID = UUID()
        for route in [TransferNoticeRoute.memo(uid: "memo-1"), .transfers(jobID: jobID)] {
            let notice = TransferNotice(
                jobID: jobID, kind: .live, title: "t", subtitle: "", body: "", route: route)
            let request = SystemNoticeCenter.request(for: notice)
            #expect(TransferNoticeRoute(userInfo: request.content.userInfo) == route)
            #expect(request.identifier == notice.identifier)
        }
        #expect(TransferNoticeRoute(userInfo: [:]) == nil)
        #expect(TransferNoticeRoute(userInfo: ["memosng.notice.route": "transfers"]) == nil)

        let inbox = TransferNoticeInbox()
        let jump = MemoJump()
        #expect(inbox.dispatch(into: jump) == nil)
        inbox.deliver(.memo(uid: "memo-1"))
        #expect(inbox.dispatch(into: jump) == .timeline)
        #expect(jump.pending == "memo-1")
        #expect(inbox.pending == nil)
        jump.clear()
        inbox.deliver(.transfers(jobID: jobID))
        #expect(inbox.dispatch(into: jump) == .timeline)
        #expect(jump.pending == nil)
        #expect(inbox.takeTransfers() == jobID)
        #expect(inbox.takeTransfers() == nil)
    }

    @Test("permission is asked once, at the first post and before it, never at launch")
    func asksOnceAtFirstPost() async {
        let center = RecordingCenter()
        let poster = TransferNoticePoster(center: center)
        #expect(center.events.isEmpty)
        let one = notice("a")
        let two = notice("b")
        poster.post([one])
        poster.post([])
        poster.post([two])
        await poster.tail?.value
        #expect(center.events == ["ask", "add \(one.identifier)", "add \(two.identifier)"])
    }

    @Test("the real outbox's reads reach the center: one notice for a held capture")
    func outboxFeedsTheCenter() async throws {
        let suite = NoticeDefaults()
        defer { suite.forget() }
        let rig = try OutboxRig()
        defer { rig.forget() }
        let center = RecordingCenter()
        let notifications = TransferNotifications(
            defaults: suite.defaults, center: center, frontmost: { false })
        notifications.attach(to: rig.outbox)
        try await rig.repository.save(
            capture(.held, hold: .tooLarge, files: files(4, done: 0)))
        await rig.outbox.refresh()
        await rig.outbox.refresh()
        await notifications.poster.tail?.value
        #expect(center.events.count == 2)
        let expected = "Too large for the server — remove it, or try again if the limit rises"
        #expect(center.posted.map(\.body) == [expected])
    }
}

private func notice(_ title: String) -> TransferNotice {
    TransferNotice(
        jobID: UUID(), kind: .held, title: title, subtitle: "", body: "",
        route: .transfers(jobID: UUID()))
}

@MainActor
private final class RecordingCenter: TransferNoticeCenter {
    var events: [String] = []
    var posted: [TransferNotice] = []

    func requestAuthorization() async -> Bool {
        events.append("ask")
        return true
    }

    func add(_ notice: TransferNotice) async {
        events.append("add \(notice.identifier)")
        posted.append(notice)
    }
}

// MARK: - The real outbox

private struct SignedIn: OutboxCredentialsProviding {
    func currentCredentials() async -> OutboxCredentials? {
        OutboxCredentials(serverBaseURL: server, ownerSubject: "alice", token: "pat-token")
    }
    func isCurrent(_ credentials: OutboxCredentials) -> Bool { true }
    func stillCurrent(epoch: Int) -> Bool { true }
}

private struct RefusingHTTP: OutboxHTTPPerforming {
    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        OutboxHTTPResponse(statusCode: 500)
    }
}

private struct NoChunks: OutboxChunkScheduling {
    func inFlight() async -> [OutboxTaskIdentity] { [] }
    func upload(
        _ request: URLRequest, fromFile file: URL, identity: OutboxTaskIdentity,
        under authority: SendAuthority, issuedUnder epoch: Int
    ) async {}
    func cancel(_ identities: [OutboxTaskIdentity]) async {}
    func cancelEveryTask() async {}
}

private struct OnMobileData: NetworkPathProviding {
    func currentPath() -> NetworkPath {
        NetworkPath(usesCellular: true, isExpensive: true, isConstrained: false)
    }
    func onPathChange(_ handler: @escaping OutboxTrigger) {}
}

@MainActor
private struct OutboxRig {
    let repository: OutboxRepository
    let outbox: Outbox
    let suite: String

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transfer-notices").appending(path: UUID().uuidString)
        let credentials = SignedIn()
        repository = try OutboxRepository(
            root: root, stillCurrent: { credentials.stillCurrent(epoch: $0) })
        suite = "transfer.notices.outbox.\(UUID().uuidString)"
        outbox = Outbox(
            repository: repository, credentials: credentials, http: RefusingHTTP(),
            scheduler: NoChunks(), completion: MemoCompletionEndpoint(http: RefusingHTTP()),
            network: OnMobileData(),
            preferences: UploadPreferences(defaults: UserDefaults(suiteName: suite)!))
    }

    func forget() { UserDefaults.standard.removePersistentDomain(forName: suite) }
}
