import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Synchronization
import Testing

/// The memos-ng 2.2.0 surface the filters and the select actions will stand on, held through the
/// REAL generated client before any store uses it: the inclusion route, the `mine` and
/// `visibility` parameters on the four listing routes, and the memo's visibility on a listed
/// attachment.
///
/// No store reads any of it yet. These tests exist so that a re-vendor which drops one of them —
/// the generator answers a schema it cannot express by skipping it — fails here, by name, instead
/// of in the first story that reaches for it.
@Suite("Filters and actions contract")
struct FiltersContractTests {
    private final class Seen: Sendable {
        let requests = Mutex<[(HTTPRequest, Data, String)]>([])
        var all: [(HTTPRequest, Data, String)] { requests.withLock { $0 } }
    }

    private static func row(uid: String, visibility: String?, orphan: Bool) -> String {
        let memo = orphan ? "null" : "\"memo-\(uid)\""
        let value = visibility.map { "\"\($0)\"" } ?? "null"
        return """
            {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
            "width":1000,"height":1000,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
            "webReady":true,"renditions":[],"tags":[],"orphan":\(orphan),"memoUid":\(memo),\
            "visibility":\(value),\
            "takenAt":"2026-09-26T10:00:00Z","filename":"\(uid).jpg",\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
            "previewUrl":"/api/attachments/\(uid)/mobile",\
            "webUrl":"/api/attachments/\(uid)/web",\
            "posterUrl":"/api/attachments/\(uid)/poster",\
            "downloadUrl":"/api/attachments/\(uid)/original",\
            "printUrl":"/api/attachments/\(uid)/print"}
            """
    }

    private static func query(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(string: request.path ?? "")?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    @Test("one inclusion call is sent with the uids alone, and every outcome decodes")
    func inclusionRequestAndOutcomes() async throws {
        let seen = Seen()
        let client = Stub.client { request, body, operation in
            let bytes = try await Stub.bytes(body)
            seen.requests.withLock { $0.append((request, bytes, operation)) }
            return Stub.json(
                """
                {"results":[\
                {"attachmentUid":"a1","outcome":"added"},\
                {"attachmentUid":"a2","outcome":"alreadyMember"},\
                {"attachmentUid":"a3","outcome":"notOwner"},\
                {"attachmentUid":"a4","outcome":"orphan"},\
                {"attachmentUid":"a5","outcome":"error"}]}
                """
            )
        }

        let response = try await client.includeAttachmentsApiCollectionsUidAttachmentsPost(
            path: .init(uid: "trip-1"),
            body: .json(.init(attachmentUids: ["a1", "a2", "a3", "a4", "a5"]))
        )

        let sent = seen.all
        #expect(sent.count == 1)
        let (request, bytes, operation) = try #require(sent.first)
        #expect(operation == "include_attachments_api_collections__uid__attachments_post")
        #expect(request.method == .post)
        #expect(request.path == "/api/collections/trip-1/attachments")
        let object = Stub.object(bytes)
        #expect(Set(object.keys) == ["attachmentUids"])
        #expect(object["attachmentUids"] as? [String] == ["a1", "a2", "a3", "a4", "a5"])

        guard case .ok(let ok) = response else {
            Issue.record("expected 200, got \(response)")
            return
        }
        let results = try ok.body.json.results
        #expect(results.map(\.attachmentUid) == ["a1", "a2", "a3", "a4", "a5"])
        #expect(
            results.map(\.outcome.rawValue)
                == ["added", "alreadyMember", "notOwner", "orphan", "error"]
        )
    }

    @Test("a trip without a tag answers the documented 409")
    func inclusionIntoTaglessTripIsConflict() async throws {
        let client = Stub.client { _, _, _ in
            Stub.detail("The collection has no tag.", status: .conflict)
        }
        let response = try await client.includeAttachmentsApiCollectionsUidAttachmentsPost(
            path: .init(uid: "trip-untagged"),
            body: .json(.init(attachmentUids: ["a1"]))
        )
        guard case .conflict = response else {
            Issue.record("expected the documented 409, got \(response)")
            return
        }
    }

    @Test("the four listing routes send mine and visibility")
    func listingRoutesCarryTheFilters() async throws {
        let seen = Seen()
        let client = Stub.client { request, _, operation in
            seen.requests.withLock { $0.append((request, Data(), operation)) }
            return Stub.json("[]")
        }

        _ = try await client.listAttachmentsApiAttachmentsGet(
            query: .init(mine: true, visibility: .protected)
        )
        _ = try await client.attachmentBucketsApiAttachmentsBucketsGet(
            query: .init(size: .day, mine: true, visibility: ._public)
        )
        _ = try await client.attachmentTagsApiAttachmentsTagsGet(
            query: .init(mine: true, visibility: .protected)
        )
        _ = try await client.listMembersApiCollectionsUidAttachmentsGet(
            path: .init(uid: "trip-1"),
            query: .init(mine: true, visibility: ._public)
        )

        let sent = seen.all
        #expect(
            sent.map(\.2) == [
                "list_attachments_api_attachments_get",
                "attachment_buckets_api_attachments_buckets_get",
                "attachment_tags_api_attachments_tags_get",
                "list_members_api_collections__uid__attachments_get",
            ]
        )
        let queries = sent.map { Self.query($0.0) }
        #expect(queries.map { $0["mine"] } == ["true", "true", "true", "true"])
        #expect(
            queries.map { $0["visibility"] } == ["PROTECTED", "PUBLIC", "PROTECTED", "PUBLIC"]
        )
    }

    @Test("a listed attachment carries its memo's visibility, and null for an orphan")
    func listedAttachmentDecodesVisibility() async throws {
        let client = Stub.client { _, _, _ in
            Stub.json(
                "[\(Self.row(uid: "p1", visibility: "PROTECTED", orphan: false)),"
                    + "\(Self.row(uid: "p2", visibility: "PUBLIC", orphan: false)),"
                    + "\(Self.row(uid: "o1", visibility: nil, orphan: true))]"
            )
        }
        let response = try await client.listAttachmentsApiAttachmentsGet(query: .init())
        guard case .ok(let ok) = response else {
            Issue.record("expected 200, got \(response)")
            return
        }
        let rows = try ok.body.json
        #expect(rows.map(\.uid) == ["p1", "p2", "o1"])
        #expect(rows.map { $0.visibility?.rawValue } == ["PROTECTED", "PUBLIC", nil])
    }

    @Test("the member route still sends an explicit kind, whose enum now lists null")
    func memberRouteSendsExplicitKind() async throws {
        let seen = Seen()
        let client = Stub.client { request, _, operation in
            seen.requests.withLock { $0.append((request, Data(), operation)) }
            return Stub.json("[]")
        }
        _ = try await client.listMembersApiCollectionsUidAttachmentsGet(
            path: .init(uid: "trip-1"),
            query: .init(_type: .image)
        )
        _ = try await client.listMembersApiCollectionsUidAttachmentsGet(
            path: .init(uid: "trip-1"),
            query: .init(_type: .video)
        )
        #expect(seen.all.map { Self.query($0.0)["type"] } == ["image", "video"])
    }

    @Test("a trip's cover keeps its row whether its memo's visibility is set or null")
    func coverWithVisibilityBecomesARow() async throws {
        let collections = [
            ("t1", Self.row(uid: "c1", visibility: "PROTECTED", orphan: false)),
            ("t2", Self.row(uid: "c2", visibility: nil, orphan: true)),
        ].map { uid, cover in
            """
            {"uid":"\(uid)","title":"Trip \(uid)","kind":"trip","tag":"trip-\(uid)",\
            "spanStart":null,"spanEnd":null,"tz":null,"cover":\(cover),"memberCount":1,\
            "createdBy":null,"createdAt":"2026-09-26T10:00:00Z",\
            "updatedAt":"2026-09-26T10:00:00Z"}
            """
        }
        let client = Stub.client { _, _, _ in
            Stub.json("[\(collections.joined(separator: ","))]")
        }
        let response = try await client.listCollectionsApiCollectionsGet(.init())
        guard case .ok(let ok) = response else {
            Issue.record("expected 200, got \(response)")
            return
        }
        let generated = try ok.body.json
        #expect(generated.map { $0.cover?.visibility?.rawValue } == ["PROTECTED", nil])
        let trips = generated.map { Trip($0, baseURL: Stub.baseURL) }
        #expect(trips.map { $0.cover?.id } == ["c1", "c2"])
    }
}
