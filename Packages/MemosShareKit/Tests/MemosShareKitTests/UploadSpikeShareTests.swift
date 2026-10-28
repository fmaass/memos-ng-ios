import Foundation
import MemosOutbox
import MemosShareKit
import Testing

// MEMNG-538 device spike — kill date 2026-11-03, with the code it pins.

private let server = URL(string: "https://memos.example.invalid")!
private let account = AccountBinding(serverBaseURL: server, ownerSubject: "fabian")
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let secret = "memos_pat_spike_secret"

private final class Record: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _sent: [URLRequest] = []
    private var _started: [(String, URLRequest, URL)] = []
    private var _grantReads = 0
    private var _licence: PublishedLicence?
    var licence: PublishedLicence? {
        get { lock.withLock { _licence } }
        set { lock.withLock { _licence = newValue } }
    }
    var lines: [String] { lock.withLock { _lines } }
    var sent: [URLRequest] { lock.withLock { _sent } }
    var started: [(String, URLRequest, URL)] { lock.withLock { _started } }
    var grantReads: Int { lock.withLock { _grantReads } }
    func log(_ line: String) { lock.withLock { _lines.append(line) } }
    func send(_ request: URLRequest) { lock.withLock { _sent.append(request) } }
    func start(_ entry: (String, URLRequest, URL)) { lock.withLock { _started.append(entry) } }
    func readGrant() { lock.withLock { _grantReads += 1 } }
}

@Suite("Share extension upload spike (MEMNG-538)")
struct UploadSpikeShareTests {
    private func run(
        enabled: Bool = true,
        binding: AccountBinding? = account,
        duringPost: PublishedLicence?? = nil,
        grant: UploadSpikeGrant? = UploadSpikeGrant(
            token: secret, expiresAt: now.addingTimeInterval(3600), binding: account),
        status: Int = 201,
        record: Record,
        root: URL
    ) async -> UploadSpikeShare.Outcome {
        let job = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        record.licence = binding.map { PublishedLicence(binding: $0, incarnation: nil) }
        return await UploadSpikeShare.run(
            jobID: job, enabled: enabled, licence: { record.licence },
            grant: {
                record.readGrant()
                return grant
            },
            root: root, now: now, size: 4096,
            log: { record.log($0) },
            send: { request in
                record.send(request)
                if let duringPost { record.licence = duringPost }
                let body = Data(
                    #"{"upload_uid":"u-1","chunk_size":5242880,"bytes_received":0}"#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (body, response)
            },
            startBackground: { identifier, request, file in
                record.start((identifier, request, file))
                return 7
            }
        )
    }

    private func scratch() -> URL {
        URL.temporaryDirectory.appending(path: "spike-share-\(UUID().uuidString)")
    }

    @Test("with the switch off nothing is read, written, sent or logged")
    func offIsInert() async {
        let record = Record()
        let root = scratch()
        let outcome = await run(enabled: false, record: record, root: root)
        #expect(outcome == .disabled)
        #expect(record.grantReads == 0)
        #expect(record.sent.isEmpty)
        #expect(record.started.isEmpty)
        #expect(record.lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("on, it opens a session and hands one PATCH of the file to the background session")
    func startsOneBackgroundPatch() async throws {
        let record = Record()
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(record: record, root: root)
        let identifier =
            "live.discomarder.memosng.uploads.share.6F9619FF-8B86-D011-B42D-00C04FC964FF"
        #expect(outcome == .started(identifier: identifier, uploadUID: "u-1"))
        #expect(record.sent.count == 1)
        #expect(record.sent.first?.httpMethod == "POST")
        let started = try #require(record.started.first)
        #expect(record.started.count == 1)
        #expect(started.0 == identifier)
        #expect(started.1.httpMethod == "PATCH")
        #expect(started.1.url?.path == "/api/uploads/u-1")
        #expect(started.1.value(forHTTPHeaderField: "Upload-Offset") == "0")
        #expect(started.1.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)")
        let size = try FileManager.default.attributesOfItem(atPath: started.2.path)[.size]
        #expect((size as? NSNumber)?.int64Value == 4096)
        #expect(record.lines.contains { $0.contains("upload_uid=u-1") })
        #expect(!record.lines.contains { $0.contains(secret) }, "the token reached the log")
    }

    @Test("a refused POST starts nothing and leaves no synthetic file behind")
    func refusedPostStartsNothing() async {
        let record = Record()
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(status: 403, record: record, root: root)
        #expect(outcome == .failed("POST status 403"))
        #expect(record.started.isEmpty)
        let directory = UploadSpike.directory(in: root).path
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test(
        "an account that changed while the POST was out starts no PATCH",
        arguments: [
            PublishedLicence?.none,
            PublishedLicence(binding: account, incarnation: UUID()),
        ]
    )
    func licenceMovedDuringPost(after: PublishedLicence?) async {
        let record = Record()
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(duringPost: .some(after), record: record, root: root)
        #expect(outcome == .failed("account changed"))
        #expect(record.sent.count == 1)
        #expect(record.started.isEmpty, "a PATCH started under a licence that had gone")
    }

    @Test("a token for another account, an expired one or none sends nothing")
    func unusableGrantSendsNothing() async {
        let other = AccountBinding(serverBaseURL: server, ownerSubject: "someone-else")
        let expired = UploadSpikeGrant(token: secret, expiresAt: now, binding: account)
        let valid = UploadSpikeGrant(
            token: secret, expiresAt: now.addingTimeInterval(3600), binding: account)
        let cases: [(AccountBinding, UploadSpikeGrant?)] = [
            (other, valid), (account, expired), (account, nil),
        ]
        for (binding, grant) in cases {
            let record = Record()
            let outcome = await run(binding: binding, grant: grant, record: record, root: scratch())
            #expect(outcome == .noGrant)
            #expect(record.sent.isEmpty)
            #expect(record.started.isEmpty)
        }
    }
}
