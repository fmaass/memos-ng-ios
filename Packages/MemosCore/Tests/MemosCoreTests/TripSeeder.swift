import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime

/// A scripted memos-ng that KEEPS its trips (MEMNG-754): the suites adapted from the device-local
/// trip store read their result back through a SECOND `TripStore` refreshing from the same server,
/// the way they once read it back through a second store over the same file. It answers list,
/// create, get, patch, delete, the member listing, the exclusion PUT/DELETE, an album's batch add
/// and a picture's DELETE from its own rows. `answer`, when given, is asked first for every
/// request and stands in for the server wherever it returns a response; anything nobody answers is
/// a 404. Every request is
/// recorded in `calls`.
final class TripServer: @unchecked Sendable {
    struct Row: Equatable {
        var uid: String
        var title: String
        var tag: String?
        var spanStart: String?
        var spanEnd: String?
        var tz: String?
        var cover: String?
        var memberCount = 0
        var exclusions: [String] = []
        /// The pictures (`TripWire` indices) its tag and span take in, before exclusions.
        var pictures: [Int] = []
        var updatedAt = "2026-10-10T14:05:00Z"
        /// As the server stores it: the sent kind, or `trip` when none was sent.
        var kind = "trip"
    }

    typealias Answer = @Sendable (HTTPRequest, String) async -> (HTTPResponse, HTTPBody?)?

    /// Asked with the operation and its 1-based count among that operation's requests, after the
    /// answer is computed and before it is returned — where a test holds a request.
    typealias Hold = @Sendable (String, Int) async -> Void

    static let deleteAttachment = "delete_attachment_api_attachments__uid__delete"
    /// An album's member DELETE (memos-ng 2.6.0): 204 whether or not the picture was a member,
    /// 409 on a trip, which has members by its tag and span and none to delete.
    static let removeMember = "remove_member_api_collections__uid__members__attachment_uid__delete"

    let calls = TripCalls()
    private let lock = NSLock()
    private var stored: [Row] = []
    private var made = 0
    private var keys: [String: String] = [:]
    private let override: Answer?
    private let deleteStatus: HTTPResponse.Status
    private let hold: Hold?
    private let failing: LockedValue<Set<String>>

    init(
        answer: Answer? = nil, deleteStatus: HTTPResponse.Status = .noContent,
        hold: Hold? = nil
    ) {
        override = answer
        self.deleteStatus = deleteStatus
        self.hold = hold
        failing = LockedValue([])
    }

    /// From now on, `operations` answer 500 and change nothing.
    func fail(_ operations: Set<String>) { failing.set(operations) }

    var rows: [Row] { lock.withLock { stored } }

    /// Lists a trip as if somebody had created it; answers its uid.
    @discardableResult
    func seed(
        title: String = "Trip", tag: String? = nil, span: TripSpan? = nil, memberCount: Int = 0,
        pictures: [Int] = [], kind: String = "trip"
    ) -> String {
        lock.withLock {
            made += 1
            let uid = "t\(made)"
            stored.append(
                Row(
                    uid: uid, title: title, tag: tag,
                    spanStart: span.map { TripWire.stamp($0.start) },
                    spanEnd: span.map { TripWire.stamp($0.end) }, tz: span?.zone,
                    memberCount: memberCount, pictures: pictures, kind: kind))
            return uid
        }
    }

    /// Somebody else's edit of a row, outside any request.
    func edit(_ uid: String, _ change: (inout Row) -> Void) {
        lock.withLock {
            guard let index = stored.firstIndex(where: { $0.uid == uid }) else { return }
            change(&stored[index])
        }
    }

    func remove(_ uid: String) { lock.withLock { stored.removeAll { $0.uid == uid } } }

    var client: any APIProtocol {
        Stub.client { request, body, operation in
            try await self.answer(request, body, operation)
        }
    }

    private func answer(
        _ request: HTTPRequest, _ body: HTTPBody?, _ operation: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let index = await calls.record(request, body, operation)
        let answered: (HTTPResponse, HTTPBody?)
        if failing.get().contains(operation) {
            answered = Stub.empty(.internalServerError)
        } else if let override, let scripted = await override(request, operation) {
            answered = scripted
        } else {
            answered = try await compute(request, index, operation)
        }
        await hold?(operation, calls.of(operation).count)
        return answered
    }

    private func compute(
        _ request: HTTPRequest, _ index: Int, _ operation: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let sent = Stub.object(calls.all[index].body)
        let path = (request.path ?? "").split(separator: "?").first ?? ""
        let parts = path.split(separator: "/").map(String.init)
        let uid = parts.count > 2 ? parts[2] : ""
        switch operation {
        case TripWire.list:
            return Stub.json("[\(rows.map(Self.json).joined(separator: ","))]")
        case TripWire.create:
            return lock.withLock {
                let key = sent["idempotencyKey"] as? String ?? UUID().uuidString
                if let earlier = keys[key], let row = stored.first(where: { $0.uid == earlier }) {
                    return Stub.json(Self.json(row), status: .created)
                }
                made += 1
                let row = Row(
                    uid: "t\(made)", title: sent["title"] as? String ?? "",
                    tag: sent["tag"] as? String, spanStart: sent["spanStart"] as? String,
                    spanEnd: sent["spanEnd"] as? String, tz: sent["tz"] as? String,
                    kind: sent["kind"] as? String ?? "trip")
                stored.append(row)
                keys[key] = row.uid
                return Stub.json(Self.json(row), status: .created)
            }
        case TripWire.get:
            guard let row = rows.first(where: { $0.uid == uid }) else {
                return Stub.detail("Not Found", status: .notFound)
            }
            return Stub.json(Self.json(row))
        case TripWire.patch:
            return lock.withLock {
                guard let at = stored.firstIndex(where: { $0.uid == uid }) else {
                    return Stub.detail("Not Found", status: .notFound)
                }
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
                return Stub.json(Self.json(stored[at]))
            }
        case TripWire.delete:
            return lock.withLock {
                guard stored.contains(where: { $0.uid == uid }) else {
                    return Stub.detail("Not Found", status: .notFound)
                }
                stored.removeAll { $0.uid == uid }
                return Stub.empty(.noContent)
            }
        case TripWire.members:
            guard let row = rows.first(where: { $0.uid == uid }) else {
                return Stub.detail("Not Found", status: .notFound)
            }
            let visible = Self.visible(row)
            let start = Int(TripWire.query(request.path ?? "", "cursor") ?? "0") ?? 0
            let limit = Int(TripWire.query(request.path ?? "", "limit") ?? "60") ?? 60
            let end = min(start + limit, visible.count)
            let slice = start < end ? Array(visible[start..<end]) : []
            return TripWire.page(slice, next: end < visible.count ? String(end) : nil)
        case TripWire.library:
            // A tag's pictures, before any trip's exclusions — what the Removed list starts from.
            let tag = TripWire.query(request.path ?? "", "tag")
            let tagged = Set(rows.filter { $0.tag != nil && $0.tag == tag }.flatMap(\.pictures))
            return TripWire.page(tagged.sorted())
        case TripWire.exclude, TripWire.include:
            return lock.withLock {
                guard let at = stored.firstIndex(where: { $0.uid == uid }), parts.count > 4 else {
                    return Stub.detail("Not Found", status: .notFound)
                }
                guard stored[at].kind == "trip" else {
                    return Stub.detail("albumHasNoExclusions", status: .conflict)
                }
                let picture = parts[4]
                stored[at].exclusions.removeAll { $0 == picture }
                if operation == TripWire.exclude { stored[at].exclusions.append(picture) }
                return Stub.empty(.noContent)
            }
        case TripWire.add:
            // An album's add: a picture it lists is `alreadyMember`, any other one is `added`.
            return lock.withLock {
                guard let at = stored.firstIndex(where: { $0.uid == uid }) else {
                    return Stub.detail("Not Found", status: .notFound)
                }
                let named = sent["attachmentUids"] as? [String] ?? []
                var results: [String] = []
                for picture in named {
                    let listed = Self.visible(stored[at]).contains { TripWire.uid($0) == picture }
                    if !listed, let index = Int(picture.dropFirst()) {
                        stored[at].exclusions.removeAll { $0 == picture }
                        if !stored[at].pictures.contains(index) {
                            stored[at].pictures.append(index)
                        }
                    }
                    let outcome = listed ? "alreadyMember" : "added"
                    results.append(
                        "{\"attachmentUid\":\"\(picture)\",\"outcome\":\"\(outcome)\"}")
                }
                return Stub.json("{\"results\":[\(results.joined(separator: ","))]}")
            }
        case Self.removeMember:
            return lock.withLock {
                guard let at = stored.firstIndex(where: { $0.uid == uid }), parts.count > 4 else {
                    return Stub.detail("Not Found", status: .notFound)
                }
                guard stored[at].kind == "album" else {
                    return Stub.detail("notAnAlbum", status: .conflict)
                }
                let picture = parts[4]
                stored[at].pictures.removeAll { TripWire.uid($0) == picture }
                return Stub.empty(.noContent)
            }
        case Self.deleteAttachment:
            guard (200..<300).contains(deleteStatus.code) else { return Stub.empty(deleteStatus) }
            return lock.withLock {
                // The picture leaves every trip it was in, and the counts with it.
                for at in stored.indices {
                    stored[at].pictures.removeAll { TripWire.uid($0) == uid }
                }
                return Stub.empty(deleteStatus)
            }
        default:
            return Stub.detail("Not Found", status: .notFound)
        }
    }

    /// A row's members as the server lists them: its pictures less its exclusions.
    static func visible(_ row: Row) -> [Int] {
        row.pictures.filter { !row.exclusions.contains(TripWire.uid($0)) }
    }

    static func json(_ row: Row) -> String {
        TripWire.collection(
            row.uid, title: Stub.jsonEscaped(row.title), kind: row.kind,
            tag: row.tag.map(Stub.jsonEscaped),
            spanStart: row.spanStart, spanEnd: row.spanEnd, tz: row.tz,
            cover: row.cover.map { TripWire.item($0, taken: TripWire.taken(0)) },
            memberCount: row.pictures.isEmpty ? row.memberCount : visible(row).count,
            updatedAt: row.updatedAt)
    }
}

/// The trip store and member store over a `TripServer`, filled by a REAL `refresh`.
@MainActor
struct TripSeeder {
    let server: TripServer
    let root: URL
    let identity: TimelineSnapshotIdentity

    init(
        server: TripServer = TripServer(), root: URL = TripWire.root(),
        identity: TimelineSnapshotIdentity = TripWire.alice
    ) {
        self.server = server
        self.root = root
        self.identity = identity
    }

    /// A fresh trip store over the same root, refreshed from the server: the read-back.
    func store(_ identity: TimelineSnapshotIdentity? = nil) async -> TripStore {
        let store = TripStore(identity: identity ?? self.identity, root: root)
        await store.refresh(using: server.client.handle, baseURL: Stub.baseURL)
        return store
    }

    /// A member store over a freshly refreshed trip store.
    func members(
        pageSize: Int = TripMemberStore.pageSize, memberCap: Int = TripMemberStore.memberCap,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) async -> (trips: TripStore, members: TripMemberStore) {
        let trips = await store()
        let members = TripMemberStore(
            trips: trips, pageSize: pageSize, memberCap: memberCap, onUnauthorized: onUnauthorized)
        return (trips, members)
    }
}
