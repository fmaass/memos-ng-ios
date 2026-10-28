import Foundation
import MemosOutbox
import Testing

// MEMNG-538 device spike — kill date 2026-11-03, with the code it pins.

private let server = URL(string: "https://memos.example.invalid")!
private let job = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
private let account = AccountBinding(serverBaseURL: server, ownerSubject: "fabian")
private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Upload spike (MEMNG-538)")
struct UploadSpikeTests {
    @Test("the switch is off unless the pane turned it on")
    func switchDefaultsOff() throws {
        let name = "upload-spike-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!UploadSpike.isEnabled(defaults))
        defaults.set(true, forKey: UploadSpike.toggleKey)
        #expect(UploadSpike.isEnabled(defaults))
    }

    @Test("a share's session identifier names its job and reads back to it")
    func identifierRoundTrip() {
        let identifier = UploadSpike.sessionIdentifier(jobID: job)
        let expected =
            "live.discomarder.memosng.uploads.share." + "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        #expect(identifier == expected)
        #expect(UploadSpike.jobID(fromSessionIdentifier: identifier) == job)
        #expect(UploadSpike.isSpikeSession(identifier))
    }

    @Test("the outbox's own sessions are never taken for a spike session")
    func outboxSessionsAreNotSpike() {
        for identifier in [OutboxSession.identifier, OutboxUploadSession.identifier] {
            #expect(!UploadSpike.isSpikeSession(identifier), "\(identifier)")
        }
        #expect(!UploadSpike.isSpikeSession(UploadSpike.identifierPrefix))
        #expect(!UploadSpike.isSpikeSession(UploadSpike.identifierPrefix + "not-a-uuid"))
        #expect(!UploadSpike.isSpikeSession("x" + UploadSpike.sessionIdentifier(jobID: job)))
    }

    @Test("the upload is ONE PATCH from offset 0 with the headers append_chunk reads, Wi-Fi only")
    func uploadRequestShape() {
        let request = UploadSpike.uploadRequest(baseURL: server, token: "pat-x", uploadUID: "u1")
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://memos.example.invalid/api/uploads/u1")
        #expect(request.value(forHTTPHeaderField: "Upload-Offset") == "0")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pat-x")
        #expect(request.httpBody == nil, "the body is the file the background task is handed")
        #expect(!request.allowsCellularAccess)
    }

    @Test("the session is opened for the synthetic file's whole size")
    func startRequestShape() throws {
        let request = try UploadSpike.startRequest(baseURL: server, token: "pat-x", jobID: job)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://memos.example.invalid/api/uploads")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["size"] as? NSNumber)?.int64Value == 314_572_800)
        #expect(json["mime"] as? String == "application/octet-stream")
    }

    @Test("the background configuration shares the app group and asks for launch events")
    func backgroundConfiguration() {
        let identifier = UploadSpike.sessionIdentifier(jobID: job)
        let configuration = UploadSpike.backgroundConfiguration(identifier: identifier)
        #expect(configuration.identifier == identifier)
        #expect(configuration.sharedContainerIdentifier == "group.live.discomarder.memosng")
        #expect(configuration.sessionSendsLaunchEvents)
        #expect(!configuration.isDiscretionary)
    }

    @Test(
        "the synthetic file is exactly the size asked for, whatever the block",
        arguments: [(Int64(10_000), 4096), (Int64(8192), 4096), (Int64(0), 4096), (Int64(1), 4096)]
    )
    func syntheticFileSize(size: Int64, block: Int) throws {
        let url = URL.temporaryDirectory.appending(path: "spike-\(UUID().uuidString)/f.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try UploadSpike.writeSyntheticFile(to: url, size: size, block: block)
        let written = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        #expect(written?.int64Value == size)
    }

    @Test("a stored token is reused while it outlasts the margin, and minted otherwise")
    func reuseOrMint() {
        func grant(expiresIn seconds: TimeInterval, for binding: AccountBinding = account)
            -> UploadSpikeGrant
        {
            UploadSpikeGrant(
                token: "pat-x", expiresAt: now.addingTimeInterval(seconds), binding: binding)
        }
        let other = AccountBinding(serverBaseURL: server, ownerSubject: "someone-else")
        #expect(UploadSpikeGrant.decision(stored: nil, binding: nil, now: now) == .notSignedIn)
        #expect(UploadSpikeGrant.decision(stored: nil, binding: account, now: now) == .mint)
        #expect(
            UploadSpikeGrant.decision(
                stored: grant(expiresIn: 86_400, for: other), binding: account, now: now) == .mint)
        #expect(
            UploadSpikeGrant.decision(stored: grant(expiresIn: 3600), binding: account, now: now)
                == .mint)
        #expect(
            UploadSpikeGrant.decision(stored: grant(expiresIn: 86_400), binding: account, now: now)
                == .reuse(expiresAt: now.addingTimeInterval(86_400)))
    }

    @Test("a share presents the token only for its own account and before it expires")
    func usableForShare() {
        let grant = UploadSpikeGrant(
            token: "pat-x", expiresAt: now.addingTimeInterval(60), binding: account)
        #expect(grant.isUsable(for: account, at: now))
        #expect(!grant.isUsable(for: account, at: now.addingTimeInterval(60)))
        #expect(!grant.isUsable(for: nil, at: now))
        #expect(
            !grant.isUsable(
                for: AccountBinding(serverBaseURL: server, ownerSubject: "other"), at: now))
    }

    @Test("a grant never prints its secret")
    func descriptionRedacts() {
        let grant = UploadSpikeGrant(token: "memos_pat_secret", expiresAt: now, binding: account)
        #expect(!"\(grant)".contains("memos_pat_secret"))
        #expect("\(grant)".contains("fabian"))
    }

    @Test("the token file is empty until saved, reads back the last save, owner-only, no backup")
    func grantFileRoundTrip() throws {
        let root = URL.temporaryDirectory.appending(path: "spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UploadSpikeGrantFile(root: root)
        #expect(try store.load() == nil)
        let grant = UploadSpikeGrant(token: "memos_pat_secret", expiresAt: now, binding: account)
        try store.save(grant)
        #expect(try store.load() == grant)
        let replaced = UploadSpikeGrant(token: "memos_pat_next", expiresAt: now, binding: account)
        try store.save(replaced)
        #expect(try UploadSpikeGrantFile(root: root).load() == replaced)
        let path = root.appending(path: "upload-spike/grant.json").path(percentEncoded: false)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let backup = try root.appending(path: "upload-spike/grant.json")
            .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(backup == true)
        let folder = try root.appending(path: "upload-spike", directoryHint: .isDirectory)
            .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(folder == true)
    }

    @Test("without an app-group container the token file refuses rather than pretending")
    func grantFileWithoutContainer() {
        let store = UploadSpikeGrantFile(root: nil)
        #expect(throws: UploadSpikeGrantFile.Failure.noContainer) { try store.load() }
        let grant = UploadSpikeGrant(token: "memos_pat_secret", expiresAt: now, binding: account)
        #expect(throws: UploadSpikeGrantFile.Failure.noContainer) { try store.save(grant) }
    }

    @Test("a wake is answered once, by whichever of its two answers claims first")
    func wakeClaimIsOneShot() {
        let claim = UploadSpikeWakeClaim()
        #expect(claim.claim().isEmpty, "nothing is held before a wake is armed")
        let first = claim.arm()
        #expect(claim.claim() == [first])
        #expect(claim.claim(ticket: first).isEmpty, "the fallback lost to didFinishEvents")
        #expect(claim.claim().isEmpty)
    }

    @Test("two overlapping wakes are each answered exactly once, each fallback still valid")
    func overlappingWakesBothAnswered() {
        let claim = UploadSpikeWakeClaim()
        let first = claim.arm()
        let second = claim.arm()
        #expect(claim.claim(ticket: first) == [first], "wake 1's fallback was taken as stale")
        #expect(claim.claim() == [second])
        let third = claim.arm()
        let fourth = claim.arm()
        #expect(claim.claim() == [third, fourth], "finishing events left a held wake behind")
        #expect(claim.claim(ticket: third).isEmpty)
        #expect(claim.claim(ticket: fourth).isEmpty)
    }

    @Test("the receiver calls every held handler once when two wakes overlap")
    func receiverAnswersOverlappingWakes() {
        let root = URL.temporaryDirectory.appending(path: "spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let answers = Answers()
        let receiver = UploadSpikeReceiver(
            identifier: UploadSpike.sessionIdentifier(jobID: job), root: root,
            answer: { answers.add($0) })
        let first = receiver.claim.arm()
        let second = receiver.claim.arm()
        let session = URLSession(configuration: .ephemeral)
        receiver.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        #expect(!receiver.answerOnce(ticket: first, reason: "fallback"))
        #expect(!receiver.answerOnce(ticket: second, reason: "fallback"))
        #expect(answers.all == [first, second])
    }

    @Test("the receiver answers the system once when events finish twice")
    func receiverAnswersOnce() async {
        let root = URL.temporaryDirectory.appending(path: "spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let answers = Answers()
        let receiver = UploadSpikeReceiver(
            identifier: UploadSpike.sessionIdentifier(jobID: job), root: root,
            answer: { answers.add($0) })
        let ticket = receiver.claim.arm()
        let session = URLSession(configuration: .ephemeral)
        receiver.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        receiver.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        #expect(!receiver.answerOnce(ticket: ticket, reason: "fallback"))
        #expect(answers.all == [ticket])
        let log = (try? String(contentsOf: UploadSpike.logURL(in: root), encoding: .utf8)) ?? ""
        #expect(log.contains("completion handler called (didFinishEvents"))
    }

    @Test("log lines carry a timestamp and the message")
    func logLine() {
        #expect(UploadSpikeLog.line("ext: x", at: now) == "2027-01-15T08:00:00.000Z ext: x\n")
    }
}

private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ value: Int) { lock.withLock { values.append(value) } }
    var all: [Int] { lock.withLock { values } }
}
