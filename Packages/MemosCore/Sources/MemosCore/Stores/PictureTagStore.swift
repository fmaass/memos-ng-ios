import Foundation
import MemosAPI

/// The pictures' OWN tags with picture counts (MEMNG-867), read from
/// `GET /api/attachments/picture-tags` — never the memo tags `LibraryTagStore` counts.
///
/// Modelled on `LibraryTagStore` and fenced the same way: one read per kind at a time, an answer
/// for a kind nobody shows any more or for a session that has ended is dropped. One fence more:
/// a count cannot be patched row by row, so an answer whose read was ISSUED before a favorites
/// commit landed is discarded whole and the read is issued again, once. A commit that lands after
/// the answer marks the list stale (`isStale`) for whoever shows it to read again.
@MainActor
@Observable
public final class PictureTagStore {
    /// In the server's order: most pictures first, then by name.
    public private(set) var tags: [LibraryTag] = []
    public private(set) var loadedFilter: MediaLibraryFilter?
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    /// A favorites commit landed after `tags` was read: the counts may be behind.
    public private(set) var isStale = false

    private var generation = 0
    private var loadingLineage: Lineage?
    private weak var favorites: FavoriteStore?
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

    public func reports(to session: any SessionReporting) { self.session = session }

    /// Fences every read by `favorites`' revision and marks the list stale on each commit.
    public func follow(_ favorites: FavoriteStore) {
        self.favorites = favorites
        favorites.observe { [weak self] _ in self?.isStale = true }
    }

    private struct Lineage: Equatable {
        var generation: Int
        var filter: MediaLibraryFilter
    }

    public func load(for filter: MediaLibraryFilter, using handle: SessionHandle) async {
        guard loadingLineage?.filter != filter else { return }
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
        var reissued = false
        while true {
            let issued = favorites?.stamp
            do {
                let rows = try await Self.tags(
                    handle.client, filter: filter, visibility: self.visibility)
                guard lineage == Lineage(generation: generation, filter: filter) else {
                    MemosLog.api.info("picture tags answered for a kind that has moved on")
                    return
                }
                guard sessionStillCurrent(handle) else {
                    MemosLog.api.info("picture tags answered for a session that has ended")
                    return
                }
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                let now = favorites?.revision ?? 0
                let behind = issued.map { $0.revision < now } ?? false
                if behind, !reissued {
                    MemosLog.api.info("picture tags read before a favorite landed; read again")
                    reissued = true
                    continue
                }
                tags = rows
                loadedFilter = filter
                lastError = nil
                isStale = behind
                return
            } catch {
                guard lineage == Lineage(generation: generation, filter: filter) else { return }
                await report(error, issuedUnder: handle)
                return
            }
        }
    }

    public func sessionIdentityChanged() {
        tags = []
        loadedFilter = nil
        lastError = nil
        loadingLineage = nil
        isLoading = false
        isStale = false
        generation += 1
    }

    /// The same funnel, in the same order, as `LibraryTagStore.report`.
    private func report(_ error: any Error, issuedUnder handle: SessionHandle) async {
        guard sessionStillCurrent(handle) else { return }
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
        guard let apiError = StoreFailure.reportable(error) else { return }
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
        let response = try await client.attachmentPictureTagsApiAttachmentsPictureTagsGet(
            .init(query: .init(_type: filter.apiType, visibility: visibility.apiVisibility))
        )
        switch response {
        case .ok(let ok):
            return try ok.body.json.map { LibraryTag(name: $0.name, count: $0.count) }
        case .unprocessableContent:
            throw APIError.server(status: 422)
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }
}
