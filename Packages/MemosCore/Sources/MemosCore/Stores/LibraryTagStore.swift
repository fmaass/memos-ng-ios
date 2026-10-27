import Foundation
import MemosAPI

/// One row of the Library's tag menu: a tag and how many pictures carry it.
public struct LibraryTag: Sendable, Equatable, Identifiable {
    public let name: String
    public let count: Int
    public var id: String { name }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// The tags the Library can be narrowed to, with PICTURE counts (MEMNG-513).
///
/// Read from `GET /api/attachments/tags`, never from `GET /api/tags`: the latter counts MEMOS, and
/// a menu over a grid of files that promised "travel (3)" and then showed eleven pictures would be
/// answering a different question from the one on screen.
///
/// The counts follow the kind the Library shows. The operation takes the same optional `type` the
/// list takes and defines a tag's count as the length of the list under that tag and that type,
/// so the store is always asked FOR a `MediaLibraryFilter`, mapped exactly as the list maps it
/// (`MediaLibraryFilter.apiType`), and a tag that carries no videos is simply absent under Videos.
///
/// Its fences are the library's, for the library's reasons:
///
/// * one read per kind at a time — a second `load` for the kind already being read is refused,
///   not issued, so two appearances in a row are one request on the wire;
/// * an answer for a kind nobody is showing any more is dropped (a generation bumped by every read
///   and by `sessionIdentityChanged`, plus the kind itself);
/// * an answer for a session that has ended is dropped, so a stale list cannot repopulate a menu
///   that was emptied at sign-out;
/// * a failure leaves the previous list standing, and is said the way `MediaLibraryStore` says it.
@MainActor
@Observable
public final class LibraryTagStore {
    /// In the server's order.
    public private(set) var tags: [LibraryTag] = []
    /// The kind `tags` was read for, or nil before any answer — which is what lets a caller tell
    /// "no tag is left under this kind" from "nothing has been read under it yet".
    public private(set) var loadedFilter: MediaLibraryFilter?
    public private(set) var isLoading = false
    public private(set) var lastError: String?

    private var generation = 0
    private var loadingLineage: Lineage?
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    private var session: (any SessionReporting)?

    /// Whose memos' pictures are counted, fixed for the store's life (MEMNG-933): the Collections
    /// root's Tags row reads Public, so a Just us picture is counted only inside its trip.
    public let visibility: MediaVisibilityFilter

    public init(
        visibility: MediaVisibilityFilter = .any,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.visibility = visibility
        self.onUnauthorized = onUnauthorized
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    private struct Lineage: Equatable {
        var generation: Int
        var filter: MediaLibraryFilter
    }

    /// Reads the tags under one kind.
    public func load(for filter: MediaLibraryFilter, using handle: SessionHandle) async {
        let client = handle.client
        guard loadingLineage?.filter != filter else { return }
        // A read for another kind supersedes whatever is in flight: that answer is for a kind
        // nobody is showing any more.
        generation += 1
        let lineage = Lineage(generation: generation, filter: filter)
        loadingLineage = lineage
        isLoading = true
        defer {
            if loadingLineage == lineage {
                loadingLineage = nil
                isLoading = false
            }
        }
        do {
            let rows = try await Self.tags(client, filter: filter, visibility: self.visibility)
            guard lineage == currentLineage(for: filter) else {
                MemosLog.api.info("GET /api/attachments/tags answered for a kind that has moved on")
                return
            }
            guard sessionStillCurrent(handle) else {
                MemosLog.api.info("a tag list answered for a session that has ended is not applied")
                return
            }
            tags = rows
            loadedFilter = filter
            lastError = nil
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard lineage == currentLineage(for: filter) else {
                MemosLog.api.info("GET /api/attachments/tags failed for a kind that has moved on")
                return
            }
            await report(error, issuedUnder: handle)
        }
    }

    /// Empties the menu because this device is signed in as somebody else: the outgoing account's
    /// tags are not the incoming one's, and a read in flight was asked for by somebody else.
    public func sessionIdentityChanged() {
        tags = []
        loadedFilter = nil
        lastError = nil
        loadingLineage = nil
        isLoading = false
        generation += 1
    }

    private func currentLineage(for filter: MediaLibraryFilter) -> Lineage {
        Lineage(generation: generation, filter: filter)
    }

    /// The same funnel, in the same order, as `MediaLibraryStore.report`.
    private func report(_ error: any Error, issuedUnder handle: SessionHandle) async {
        guard sessionStillCurrent(handle) else {
            MemosLog.api.info("a failure for a session that has ended is not reported")
            return
        }
        if let failure = StoreFailure.transportFailure(error) {
            lastError = nil
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            return
        }
        if let refusal = StoreFailure.refusal(error) {
            if await onUnauthorized(refusal) == .endedSession, nothingEstablishedSince(handle) {
                lastError = refusal.errorDescription
            }
            return
        }
        guard let apiError = StoreFailure.reportable(error) else {
            MemosLog.api.info("a cancelled request is not a failure and is not reported")
            return
        }
        lastError = apiError.errorDescription
    }

    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }

    private func nothingEstablishedSince(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        return session.nothingEstablishedSince(handle)
    }

    static func tags(
        _ client: any APIProtocol, filter: MediaLibraryFilter,
        visibility: MediaVisibilityFilter = .any
    ) async throws -> [LibraryTag] {
        let response = try await client.attachmentTagsApiAttachmentsTagsGet(
            .init(query: .init(_type: filter.apiType, visibility: visibility.apiVisibility))
        )
        switch response {
        case .ok(let ok):
            let rows = try ok.body.json
            MemosLog.api.info(
                "GET /api/attachments/tags -> 200, \(rows.count, privacy: .public) tags"
            )
            return rows.map { LibraryTag(name: $0.name, count: $0.count) }
        case .unprocessableContent:
            throw APIError.server(status: 422)
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }
}
