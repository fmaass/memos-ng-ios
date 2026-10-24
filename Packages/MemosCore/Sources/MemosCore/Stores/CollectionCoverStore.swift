import Foundation
import MemosAPI

/// The chosen covers of the collections the Collections root computes — tags, months and years
/// (MEMNG-842) — as the household's server keeps them on `/api/collection-covers` (memos-ng
/// 2.5.0). A trip's chosen cover is its record's (`TripStore`); the favorites collection has no
/// server kind and no chosen cover.
///
/// It is server state, so it outlives a refresh and a reinstall: `load` reads the list, and each
/// chosen picture's own record (`TripMemberStore.attachment`) for the URLs its card draws. The
/// server lists only covers whose picture the reader may see; a card whose chosen picture is
/// missing here shows its default cover, and a collection's own screen keeps a carried cover only
/// while it is a drained member (`TripMemberStore.summary(of:rows:complete:deleted:)`).
///
/// Its fences:
///
/// * one list read at a time — a `load` while one is on the wire under the same generation joins
///   it;
/// * one write per collection on the wire: a `choose` of a collection whose write is still out is
///   REFUSED (it returns nil and sends nothing), never queued, so two taps are one request;
/// * a choice shows at once; a failed write puts the earlier cover back unless another choice has
///   replaced it since, and throws what the screen says about it; a list that was asked before a choice cannot undo it on arrival —
///   each collection's write epoch at the list's issue is compared on landing;
/// * every answer is judged against the generation that issued it, moved by
///   `sessionIdentityChanged`, and the session generation of the handle that sent it;
/// * a refused credential goes to `onUnauthorized` as the one typed `CredentialRefusal`, through
///   the shared `StoreFailure` funnel.
@MainActor
@Observable
public final class CollectionCoverStore {
    /// A collection a cover can be chosen for: the server's `kind` and `key`.
    public struct Key: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            case tag, month, year
        }

        public let kind: Kind
        public let key: String

        public init(kind: Kind, key: String) {
            self.kind = kind
            self.key = key
        }

        /// The key of a computed collection, or nil for one the server keeps no cover for — the
        /// favorites collection, whose pictures carry a picture tag of their own.
        public init?(_ collection: AutomaticCollection.Kind) {
            switch collection {
            case .tag(let name): self.init(kind: .tag, key: name)
            case .month(let key): self.init(kind: .month, key: key)
            case .year(let key): self.init(kind: .year, key: key)
            case .pictureTag: return nil
            }
        }
    }

    /// The chosen picture's uid of each collection, as last listed or chosen here.
    private var chosen: [Key: String] = [:]
    /// Each chosen picture's own record, its URLs signed when it was read.
    private var pictures: [String: MemoAttachment] = [:]
    /// Moved by each choice of a collection: a list asked before it does not land over it.
    private var writeEpochs: [Key: Int] = [:]
    /// The token of each collection's write on the wire.
    private var writes: [Key: Int] = [:]
    private var listing: (token: Int, generation: Int, task: Task<Void, Never>)?
    private var generation = 0
    private var nextToken = 0
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    private var session: (any SessionReporting)?

    public init(
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.onUnauthorized = onUnauthorized
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    /// The chosen picture of `key`, ready to draw, or nil for the collection's default cover.
    public func cover(for key: Key) -> MemoAttachment? {
        guard let uid = chosen[key] else { return nil }
        return pictures[uid]
    }

    /// The chosen cover of a computed collection, or nil for its default.
    public func cover(of collection: AutomaticCollection.Kind) -> MemoAttachment? {
        Key(collection).flatMap { cover(for: $0) }
    }

    /// The uid of `key`'s chosen picture, drawn or not yet.
    public func chosenUid(for key: Key) -> String? { chosen[key] }

    /// Whether a choice of `key` is on the wire.
    public func isSaving(_ key: Key) -> Bool { writes[key] != nil }

    /// Reads every chosen cover, then the record of each picture not held or whose signature is
    /// spent. A list of this generation already on the wire is joined; a caller whose session has
    /// been replaced sends nothing.
    public func load(using handle: SessionHandle, baseURL: URL) async {
        if let listing, listing.generation == generation {
            await listing.task.value
            return
        }
        guard sessionStillCurrent(handle) else { return }
        nextToken += 1
        let token = nextToken
        let issued = generation
        let epochs = writeEpochs
        let task = Task {
            await self.runLoad(token: token, issued: issued, epochs: epochs, handle, baseURL)
        }
        listing = (token, issued, task)
        await task.value
    }

    private func runLoad(
        token: Int, issued: Int, epochs: [Key: Int], _ handle: SessionHandle, _ baseURL: URL
    ) async {
        defer { if listing?.token == token { listing = nil } }
        let rows: [Components.Schemas.CollectionCoverOut]
        do {
            rows = try await Self.list(handle.client)
        } catch {
            guard issued == generation else { return }
            await report(error, issuedUnder: handle)
            return
        }
        guard issued == generation, sessionStillCurrent(handle) else {
            MemosLog.api.info("collection covers answered for a credential that has gone; dropped")
            return
        }
        chosen = Self.merged(
            listed: rows, held: chosen, epochsAtIssue: epochs, epochsNow: writeEpochs,
            pending: Set(writes.keys))
        session?.noteTransportSuccess(issuedUnder: handle.generation)
        let now = Date()
        for uid in Set(chosen.values).sorted()
        where pictures[uid].map({ $0.isPastURLHorizon(at: now) }) ?? true {
            do {
                let picture = try await TripMemberStore.attachment(
                    handle.client, uid: uid, baseURL: baseURL)
                guard issued == generation, sessionStillCurrent(handle) else { return }
                pictures[uid] = picture
            } catch {
                guard issued == generation else { return }
                // A refusal ends the reads; anything else leaves that card on its default.
                if StoreFailure.refusal(error) != nil {
                    await report(error, issuedUnder: handle)
                    return
                }
            }
        }
    }

    /// What a landing list makes of the chosen covers: the server's, except for a collection
    /// chosen here after the list was asked — that choice is newer than the answer — and for one
    /// whose choice is still being written (`pending`): a list asked while the write was out may
    /// have been read before the write reached the server, so it says nothing about the choice.
    static func merged(
        listed: [Components.Schemas.CollectionCoverOut], held: [Key: String],
        epochsAtIssue: [Key: Int], epochsNow: [Key: Int], pending: Set<Key> = []
    ) -> [Key: String] {
        var next: [Key: String] = [:]
        for row in listed {
            guard let kind = Key.Kind(rawValue: row.kind.rawValue) else { continue }
            next[Key(kind: kind, key: row.key)] = row.attachmentUid
        }
        for key in Set(next.keys).union(held.keys)
        where pending.contains(key)
            || epochsNow[key, default: 0] != epochsAtIssue[key, default: 0]
        {
            next[key] = held[key]
        }
        return next
    }

    /// Makes `picture` the cover of `key` for the household: drawn at once, written to the
    /// server, put back to the earlier cover if the write fails while it is still the choice.
    /// Nil, with nothing sent, while a write of `key` is on the wire or for a replaced session;
    /// otherwise the write, which throws the `TripStore.Failure` a trip's cover write would, so
    /// the collection's screen says the same sentence a failed trip cover does.
    @discardableResult
    public func choose(_ picture: MemoAttachment, for key: Key, using handle: SessionHandle)
        -> Task<Void, any Error>?
    {
        guard writes[key] == nil, sessionStillCurrent(handle) else { return nil }
        nextToken += 1
        let token = nextToken
        let issued = generation
        let previous = chosen[key]
        writeEpochs[key, default: 0] += 1
        chosen[key] = picture.uid
        pictures[picture.uid] = picture
        writes[key] = token
        return Task {
            defer { if writes[key] == token { writes[key] = nil } }
            do {
                try await Self.put(handle.client, key: key, uid: picture.uid)
            } catch {
                guard issued == generation else { throw TripStore.Failure.superseded }
                if chosen[key] == picture.uid { chosen[key] = previous }
                throw await failure(error, issuedUnder: handle)
            }
            guard issued == generation else { throw TripStore.Failure.superseded }
            // A list asked while the write was out, and answering after it, may still carry the
            // earlier cover: moving the epoch again keeps that answer off the choice.
            writeEpochs[key, default: 0] += 1
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        }
    }

    /// What a failed write says once the funnel has heard it, classified as `TripStore` classifies
    /// a trip's: nothing for an answer the session has moved past or a transport failure (the
    /// session's banner says that one), the server's sentence otherwise.
    private func failure(_ error: any Error, issuedUnder handle: SessionHandle) async
        -> TripStore.Failure
    {
        await report(error, issuedUnder: handle)
        guard sessionStillCurrent(handle), !StoreFailure.isCancellation(error) else {
            return .superseded
        }
        if StoreFailure.transportFailure(error) != nil { return .transport }
        switch StoreFailure.reportable(error) {
        case .server(let status): return .server(status: status)
        case .notFound: return .server(status: 404)
        case .forbidden: return .server(status: 403)
        case nil: return .superseded
        case let other?: return .failed(other)
        }
    }

    /// Forgets every cover and drops every read and write in flight: another account's choices
    /// are not this one's, and an answer asked for the old one lands nowhere.
    public func sessionIdentityChanged() {
        chosen = [:]
        pictures = [:]
        writes = [:]
        listing = nil
        generation += 1
    }

    /// The shared funnel: a refusal goes to the session's rule, judged by the credential it
    /// names; a transport failure is said for the credential still current; nothing else is a
    /// sentence — the card keeps whatever it showed.
    private func report(_ error: any Error, issuedUnder handle: SessionHandle) async {
        if let refusal = StoreFailure.refusal(error) {
            _ = await onUnauthorized(refusal)
            return
        }
        guard sessionStillCurrent(handle) else { return }
        if let failure = StoreFailure.transportFailure(error) {
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            return
        }
        MemosLog.api.info("a collection cover read or write failed; the card keeps its cover")
    }

    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }

    // MARK: - The wire

    static func list(_ client: any APIProtocol) async throws
        -> [Components.Schemas.CollectionCoverOut]
    {
        switch try await client.listCollectionCoversApiCollectionCoversGet(.init()) {
        case .ok(let ok): return try ok.body.json
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func put(_ client: any APIProtocol, key: Key, uid: String) async throws {
        typealias Put = Operations.SetCollectionCoverApiCollectionCoversKindKeyPut
        let kind: Put.Input.Path.KindPayload =
            switch key.kind {
            case .tag: .tag
            case .month: .month
            case .year: .year
            }
        let input = Put.Input(
            path: .init(kind: kind, key: key.key), body: .json(.init(attachmentUid: uid)))
        switch try await client.setCollectionCoverApiCollectionCoversKindKeyPut(input) {
        case .ok: return
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }
}
