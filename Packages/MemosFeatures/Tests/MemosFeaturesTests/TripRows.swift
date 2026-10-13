import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime

/// memos-ng's collection routes for the Features suites: the trips a server holds, answered on
/// those routes, so a trip made, renamed, emptied of a picture or deleted reads back as the
/// server would hold it. A trip's members are the suite's own listing of its tag, asked with the
/// member request's cursor, less the pictures removed from it.
nonisolated final class TripRows: @unchecked Sendable {
    static let list = "list_collections_api_collections_get"
    static let create = "create_collection_api_collections_post"
    static let get = "get_collection_api_collections__uid__get"
    static let patch = "update_collection_api_collections__uid__patch"
    static let delete = "delete_collection_api_collections__uid__delete"
    static let members = "list_members_api_collections__uid__attachments_get"
    static let exclude = "exclude_attachment_api_collections__uid__exclusions__attachment_uid__put"
    static let include =
        "include_attachment_api_collections__uid__exclusions__attachment_uid__delete"

    static let routes: Set<String> = [list, create, get, patch, delete, members, exclude, include]

    /// A trip's member listing, asked as the transport's own attachment list is: `tag`,
    /// `spanStart` and `spanEnd` as the row holds them, and the request's own `cursor`, `limit`,
    /// `order` and `type` — each only when the request carried it — as query items.
    typealias Listing = @Sendable ([String: String]) async throws -> (HTTPResponse, HTTPBody?)

    nonisolated struct Row: Sendable {
        var uid: String
        var title: String
        var tag: String?
        var spanStart: String?
        var spanEnd: String?
        var tz: String?
        var cover: String?
        /// The count before any removal.
        var count: Int
        var exclusions: [String] = []
        var stamp = 0
    }

    nonisolated struct Call: Sendable {
        let operation: String
        let path: String
        let body: Data

        var object: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private let lock = NSLock()
    private var stored: [Row] = []
    private var made = 0
    private var keys: [String: String] = [:]
    private var failing: Set<String> = []
    private var held: Set<String> = []
    private var log: [Call] = []
    private var served: [String] = []
    private var writes = 0
    /// The cover's JSON, as the transport signs its pictures.
    private let coverItem: @Sendable (String) -> String
    /// The server's count of a row, when the suite computes it; else its seeded count less its
    /// removals.
    private var counter: (@Sendable (Row) -> Int)?

    init(
        coverItem: @escaping @Sendable (String) -> String = TripRows.item,
        counter: (@Sendable (Row) -> Int)? = nil
    ) {
        self.coverItem = coverItem
        self.counter = counter
    }

    var rows: [Row] { lock.withLock { stored } }
    var calls: [Call] { lock.withLock { log } }

    func calls(_ operation: String) -> [Call] { calls.filter { $0.operation == operation } }

    /// How many requests of `operation` got past their hold and were answered; a held request
    /// whose task was cancelled never is.
    func answered(_ operation: String) -> Int {
        lock.withLock { served.filter { $0 == operation }.count }
    }

    /// Every collection route but the reads.
    var writeCalls: [Call] {
        let written = [Self.create, Self.patch, Self.delete, Self.exclude, Self.include]
        return calls.filter { written.contains($0.operation) }
    }

    /// A trip on the server; answers its uid, `trip-1`, `trip-2`, … in the order seeded or made.
    @discardableResult
    func seed(
        _ title: String, tag: String? = nil, spanStart: String? = nil, spanEnd: String? = nil,
        tz: String? = nil, cover: String? = nil, count: Int = 0
    ) -> String {
        lock.withLock {
            made += 1
            let row = Row(
                uid: "trip-\(made)", title: title, tag: tag, spanStart: spanStart, spanEnd: spanEnd,
                tz: tz, cover: cover, count: count)
            stored.append(row)
            return row.uid
        }
    }

    func edit(_ uid: String, _ change: (inout Row) -> Void) {
        lock.withLock {
            guard let at = stored.firstIndex(where: { $0.uid == uid }) else { return }
            change(&stored[at])
            writes += 1
            stored[at].stamp = writes
        }
    }

    /// The trip leaves the server as another device's delete would take it.
    func remove(_ uid: String) { lock.withLock { stored.removeAll { $0.uid == uid } } }

    /// From here on `operations` answer 500.
    func fail(_ operations: Set<String>) { lock.withLock { failing = operations } }
    /// From here on `operation` waits before it answers, until `release`.
    func hold(_ operation: String) { lock.withLock { _ = held.insert(operation) } }
    func release(_ operation: String) { lock.withLock { _ = held.remove(operation) } }

    /// Answers a collection route, or nil for any other operation.
    func answer(
        _ request: HTTPRequest, body: HTTPBody?, operationID: String, listing: Listing
    ) async throws -> (HTTPResponse, HTTPBody?)? {
        guard Self.routes.contains(operationID) else { return nil }
        let data: Data
        if let body {
            data = try await Data(collecting: body, upTo: 1 << 20)
        } else {
            data = Data()
        }
        let path = request.path ?? ""
        let call = Call(operation: operationID, path: path, body: data)
        lock.withLock { log.append(call) }
        while lock.withLock({ held.contains(operationID) }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        lock.withLock { served.append(operationID) }
        if lock.withLock({ failing.contains(operationID) }) {
            return (HTTPResponse(status: .internalServerError), nil)
        }
        let parts = (path.split(separator: "?").first ?? "").split(separator: "/").map(String.init)
        let uid = parts.count > 2 ? parts[2] : ""
        let sent = call.object
        switch operationID {
        case Self.list:
            let all = rows.map { json($0) }.joined(separator: ",")
            return Self.json("[\(all)]")
        case Self.create:
            let row: Row = lock.withLock {
                let key = sent["idempotencyKey"] as? String ?? UUID().uuidString
                if let earlier = keys[key], let row = stored.first(where: { $0.uid == earlier }) {
                    return row
                }
                made += 1
                writes += 1
                let row = Row(
                    uid: "trip-\(made)", title: sent["title"] as? String ?? "",
                    tag: sent["tag"] as? String, spanStart: sent["spanStart"] as? String,
                    spanEnd: sent["spanEnd"] as? String, tz: sent["tz"] as? String, count: 0,
                    stamp: writes)
                stored.append(row)
                keys[key] = row.uid
                return row
            }
            return Self.json(json(row), status: .created)
        case Self.get:
            guard let row = rows.first(where: { $0.uid == uid }) else {
                return Self.missing
            }
            return Self.json(json(row))
        case Self.patch:
            let row: Row? = lock.withLock {
                guard let at = stored.firstIndex(where: { $0.uid == uid }) else { return nil }
                func apply(_ key: String, _ field: WritableKeyPath<Row, String?>) {
                    guard let value = sent[key] else { return }
                    stored[at][keyPath: field] = value as? String
                }
                if let title = sent["title"] as? String { stored[at].title = title }
                apply("tag", \.tag)
                apply("spanStart", \.spanStart)
                apply("spanEnd", \.spanEnd)
                apply("tz", \.tz)
                apply("coverAttachmentUid", \.cover)
                writes += 1
                stored[at].stamp = writes
                return stored[at]
            }
            guard let row else { return Self.missing }
            return Self.json(json(row))
        case Self.delete:
            let gone: Bool = lock.withLock {
                guard stored.contains(where: { $0.uid == uid }) else { return false }
                stored.removeAll { $0.uid == uid }
                return true
            }
            return gone ? (HTTPResponse(status: .noContent), nil) : Self.missing
        case Self.members:
            guard let row = rows.first(where: { $0.uid == uid }) else {
                return Self.missing
            }
            // The tag's pictures and the span's, as the listing answers either; a trip with
            // neither has no member. The row's criteria are the server's own; the request's
            // `order` and `type` travel as the app sent them, never supplied here, so a listing
            // that honours them answers what the app asked for.
            guard row.tag != nil || row.spanStart != nil else { return Self.json("[]") }
            var query: [String: String] = [:]
            query["tag"] = row.tag
            query["spanStart"] = row.spanStart
            query["spanEnd"] = row.spanEnd
            for name in ["cursor", "limit", "order", "type"] {
                if let value = Self.query(path, name) { query[name] = value }
            }
            let listed = try await listing(query)
            return try await Self.dropping(Set(row.exclusions), from: listed)
        default:
            let ok: Bool = lock.withLock {
                guard let at = stored.firstIndex(where: { $0.uid == uid }), parts.count > 4 else {
                    return false
                }
                let picture = parts[4]
                stored[at].exclusions.removeAll { $0 == picture }
                if operationID == Self.exclude { stored[at].exclusions.append(picture) }
                writes += 1
                stored[at].stamp = writes
                return true
            }
            return ok ? (HTTPResponse(status: .noContent), nil) : Self.missing
        }
    }

    /// One `CollectionOut`.
    func json(_ row: Row) -> String {
        func quoted(_ value: String?) -> String {
            value.map { "\"\(Self.escaped($0))\"" } ?? "null"
        }
        let updated = Date(timeIntervalSince1970: 1_791_641_100 + Double(row.stamp))
        return """
            {"uid":"\(row.uid)","title":"\(Self.escaped(row.title))","tag":\(quoted(row.tag)),\
            "spanStart":\(quoted(row.spanStart)),"spanEnd":\(quoted(row.spanEnd)),\
            "tz":\(quoted(row.tz)),"cover":\(row.cover.map(coverItem) ?? "null"),\
            "memberCount":\(count(of: row)),"createdBy":"owner",\
            "createdAt":"2026-10-10T14:05:00Z","updatedAt":"\(updated.formatted(.iso8601))"}
            """
    }

    func count(of row: Row) -> Int {
        let counter = lock.withLock { self.counter }
        return counter?(row) ?? max(0, row.count - row.exclusions.count)
    }

    /// From here on the server counts a row with `counter`.
    func counting(_ counter: @escaping @Sendable (Row) -> Int) {
        lock.withLock { self.counter = counter }
    }

    /// A plain `AttachmentListItem` for a cover.
    static func item(_ uid: String) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "renditions":[],"orphan":false,"memoUid":"m-\(uid)","tags":[],"webReady":true,\
        "takenAt":"2026-03-12T12:00:00Z","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func query(_ path: String, _ name: String) -> String? {
        URLComponents(string: path)?.queryItems?.first { $0.name == name }?.value
    }

    static func json(
        _ text: String, status: HTTPResponse.Status = .ok
    ) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(text))
    }

    /// A 404 as memos-ng writes one on these routes: the contract requires its `detail` body.
    static var missing: (HTTPResponse, HTTPBody?) {
        json("{\"detail\":\"Not Found\"}", status: .notFound)
    }

    /// The listing's page without `uids`, its continuation kept.
    static func dropping(
        _ uids: Set<String>, from listed: (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard !uids.isEmpty, let body = listed.1 else { return listed }
        let data = try await Data(collecting: body, upTo: 1 << 22)
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return (listed.0, HTTPBody(data))
        }
        let kept = items.filter { !uids.contains($0["uid"] as? String ?? "") }
        return (listed.0, HTTPBody(try JSONSerialization.data(withJSONObject: kept)))
    }
}
