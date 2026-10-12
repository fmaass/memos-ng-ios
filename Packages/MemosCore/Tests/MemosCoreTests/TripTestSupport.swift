import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime

/// The server-backed trip suites' fixtures: the wire shapes of memos-ng 2.1.0's collection routes,
/// a log of what reached the scripted transport, a hold for answers, and a session the test moves.
enum TripWire {
    static let list = "list_collections_api_collections_get"
    static let create = "create_collection_api_collections_post"
    static let get = "get_collection_api_collections__uid__get"
    static let patch = "update_collection_api_collections__uid__patch"
    static let delete = "delete_collection_api_collections__uid__delete"
    static let members = "list_members_api_collections__uid__attachments_get"
    static let exclude = "exclude_attachment_api_collections__uid__exclusions__attachment_uid__put"
    static let include =
        "include_attachment_api_collections__uid__exclusions__attachment_uid__delete"
    static let library = "list_attachments_api_attachments_get"

    static let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.org")!, subject: "alice")
    static let bob = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.org")!, subject: "bob")

    static func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "trip-store")
            .appending(path: UUID().uuidString)
    }

    static func quoted(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }

    /// One `CollectionOut`.
    static func collection(
        _ uid: String,
        title: String = "Trip",
        tag: String? = nil,
        spanStart: String? = nil,
        spanEnd: String? = nil,
        tz: String? = nil,
        cover: String? = nil,
        memberCount: Int = 0,
        updatedAt: String = "2026-10-10T14:05:00Z"
    ) -> String {
        """
        {"uid":"\(uid)","title":"\(title)","tag":\(quoted(tag)),\
        "spanStart":\(quoted(spanStart)),"spanEnd":\(quoted(spanEnd)),"tz":\(quoted(tz)),\
        "cover":\(cover ?? "null"),"memberCount":\(memberCount),"createdBy":"owner",\
        "createdAt":"2026-10-10T14:05:00Z","updatedAt":"\(updatedAt)"}
        """
    }

    /// The production record of 2026-10-10, as the server answers it for the owner.
    static let portugal = collection(
        "ptaVEyvr0EcqHDBh", title: "Portugal 2026", tag: "portugal2026",
        spanStart: "2026-09-12T22:00:00Z", spanEnd: "2026-09-20T21:59:59Z",
        tz: "Europe/Zurich", memberCount: 157)

    /// The n-th picture's taken instant: one hour apart from 2026-09-13T00:00:00Z.
    static func taken(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 1_789_257_600 + Double(index) * 3600)
    }

    static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    static func uid(_ index: Int) -> String { "p" + String(format: "%04d", index) }

    /// One `AttachmentListItem`.
    static func item(_ uid: String, taken: Date) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "renditions":[],"orphan":false,"memoUid":"m-\(uid)","tags":[],"webReady":true,\
        "takenAt":"\(stamp(taken))","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    /// Pictures `indices` as one page of a listing, with the continuation header when given.
    static func page(_ indices: [Int], next: String? = nil) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        if let next, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = next
        }
        let items = indices.map { item(uid($0), taken: taken($0)) }
        return (response, HTTPBody("[\(items.joined(separator: ","))]"))
    }

    static func query(_ path: String, _ name: String) -> String? {
        URLComponents(string: path)?.queryItems?.first { $0.name == name }?.value
    }

    static func hasQuery(_ path: String, _ name: String) -> Bool {
        URLComponents(string: path)?.queryItems?.contains { $0.name == name } ?? false
    }
}

/// What reached the scripted transport, in order.
final class TripCalls: @unchecked Sendable {
    struct Call: Sendable {
        let operation: String
        let path: String
        let body: Data
    }

    private let lock = NSLock()
    private var log: [Call] = []

    var all: [Call] { lock.withLock { log } }

    func of(_ operation: String) -> [Call] { all.filter { $0.operation == operation } }

    /// Records the request and answers its index among all calls.
    func record(_ request: HTTPRequest, _ body: HTTPBody?, _ operation: String) async -> Int {
        let bytes = (try? await Stub.bytes(body)) ?? Data()
        return lock.withLock {
            log.append(Call(operation: operation, path: request.path ?? "", body: bytes))
            return log.count - 1
        }
    }
}

/// A one-shot hand-off between a test and its transport; every wait is bounded.
final class TripLatch: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        stream = made.stream
        continuation = made.continuation
    }

    func open() { continuation.yield() }

    @discardableResult
    func wait(seconds: Double = 5) async -> Bool {
        let stream = self.stream
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

/// A session the test can move, counting what the stores report to it.
final class TripTestSession: SessionReporting {
    var activeHandle: SessionHandle?
    nonisolated let sessionIncarnation = SessionEpoch()
    private(set) var successes: [Int] = []
    private(set) var failures = 0

    init(for handle: SessionHandle) { activeHandle = handle }

    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool { true }

    func nothingEstablishedSince(_ handle: SessionHandle) -> Bool { true }

    func noteTransportFailure(_ failure: ServerReachability.Reason, issuedUnder generation: Int) {
        failures += 1
    }

    func noteTransportSuccess(issuedUnder generation: Int) { successes.append(generation) }
}
