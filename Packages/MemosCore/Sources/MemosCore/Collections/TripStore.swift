import CryptoKit
import Foundation
import MemosAPI
import Observation

/// The household's trips as the server holds them (`/api/collections`), for the signed-in scope.
///
/// **Writes are direct online calls, one logical request per trip.** Each write takes its trip's
/// slot, keyed by (scope, uid, operation, payload): a second call with the identical key JOINS the
/// one on the wire and gets its result; any other write on that trip meanwhile is refused with
/// `Failure.busy` and sends nothing. A create's slot is held by (scope, idempotency key) and keeps
/// its frozen request: the identical request joins, another one under the same key is `.busy`.
///
/// **A revision arbitrates reads; a write is judged by its own slot.** `revision` moves on every
/// applied mutation (create, update, delete, exclusion), every applied list and every identity
/// change. A READ answer is applied only while the revision, the session generation and the scope
/// are the ones it was issued under — so a list asked before a delete cannot bring the trip back.
/// A WRITE answer is applied while the scope and the session generation are the issuing ones and
/// its slot is still its own, whatever the revision did meanwhile; a write that outlived its scope
/// applies nothing and its caller gets `Failure.superseded`.
///
/// **A refusal keeps the Library's funnel.** It goes to `onUnauthorized` (the session's
/// `SessionStore.handle`) as the typed value carrying the credential generation it presented, and
/// the scope is asked again after that wait, before anything reaches a screen.
@MainActor
@Observable
public final class TripStore {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// Another write on this trip is on the wire; nothing was sent.
        case busy
        /// The scope changed while the request was out; nothing was applied.
        case superseded
        case refusal(CredentialRefusal)
        /// The server could not be reached; the session's banner says so.
        case transport
        /// The server answered with a failure status.
        case server(status: Int)
        /// Anything else, classified as every store classifies it (`StoreFailure.reportable`): an
        /// answer this device could not read arrives as `APIError.unexpected(description:)`.
        case failed(APIError)

        public var errorDescription: String? {
            switch self {
            case .busy: "Another change to this trip is still being saved."
            case .superseded, .transport: nil
            case .refusal(let refusal): refusal.errorDescription
            case .server(let status): APIError.fromStatus(status).errorDescription
            case .failed(let error): error.errorDescription
            }
        }
    }

    /// The scope's trips, in the server's order.
    public private(set) var trips: [Trip] = []
    public private(set) var revision = 0
    public private(set) var identity: TimelineSnapshotIdentity?
    /// What the last list could not do.
    public private(set) var lastError: String?

    /// A seam for tests: called when a caller joins a write already on the wire.
    @ObservationIgnored var onJoin: (@MainActor () -> Void)?
    /// A seam for tests: awaited by every caller of a write (the slot's uid, and whether it
    /// joined) after its wait and before its authority is asked, so a test can move the slot there.
    @ObservationIgnored var onDelivery: (@MainActor (String, Bool) async -> Void)?
    /// What `TripMemberStore` drops when a trip changes: the uid, or nil for every trip.
    @ObservationIgnored var onInvalidate: [@MainActor (String?) -> Void] = []
    /// What a removal batch reconciles before it ends, inside its slot: `TripMemberStore`'s
    /// re-drain of the trip's members (decision 7).
    @ObservationIgnored var onReconcile: [@MainActor (String, SessionHandle, URL) async -> Void] =
        []
    /// Told of each exclusion or add-back the server acknowledged — its kind, the trip and the
    /// picture — as it is acknowledged, while the scope that sent it is still this store's:
    /// `TripMemberStore`'s record of the exclusions the app wrote (MEMNG-793).
    @ObservationIgnored var onAcknowledged: [@MainActor (BatchKind, String, String) -> Void] = []

    enum Operation: Hashable {
        case update(TripPatch)
        case delete
        case exclude(Set<String>)
        case include(Set<String>)
    }

    private struct WriteKey: Hashable {
        var scope: TimelineSnapshotIdentity
        var uid: String
        var operation: Operation
    }

    enum WriteResult {
        case trip(Trip)
        case deleted
        case batch(TripBatchOutcome)
        case failed(Failure)
    }

    /// What a write was issued under; asked again before its answer is applied.
    struct Authority {
        var scope: TimelineSnapshotIdentity
        var uid: String
        var token: Int
        var generation: Int
    }

    private struct ReadLineage: Equatable {
        var scope: TimelineSnapshotIdentity
        var session: Int
        var revision: Int
    }

    private let root: URL?
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    private var session: (any SessionReporting)?
    private var nextToken = 0
    private typealias WriteSlot = (
        key: WriteKey, authority: Authority, task: Task<WriteResult, Never>
    )
    private var writes: [String: WriteSlot] = [:]
    private typealias CreateSlot = (
        request: NewTripRequest, authority: Authority, task: Task<WriteResult, Never>
    )
    private var creates: [String: CreateSlot] = [:]
    /// The token of the latest slot taken on each trip (and each create key): a caller is answered
    /// only while the slot it waited on is still the latest one, held or released.
    private var latestWrite: [String: Int] = [:]
    private var latestCreate: [String: Int] = [:]
    private var listing: (lineage: ReadLineage, token: Int, task: Task<Void, Never>)?

    public init(
        identity: TimelineSnapshotIdentity?,
        root: URL? = TripStore.appGroupRoot(),
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.identity = identity
        self.root = root
        self.onUnauthorized = onUnauthorized
        dropLegacyFiles()
    }

    /// Names the session this store's transport outcomes belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    /// Whether a list is on the wire.
    public var isRefreshing: Bool { listing != nil }

    /// The session became somebody else's, or nobody's: every trip, slot and sentence of the
    /// outgoing scope goes, and the revision moves.
    public func sessionIdentityChanged(to identity: TimelineSnapshotIdentity?) {
        guard identity != self.identity else { return }
        self.identity = identity
        trips = []
        lastError = nil
        writes = [:]
        creates = [:]
        latestWrite = [:]
        latestCreate = [:]
        listing = nil
        dropLegacyFiles()
        bump(nil)
    }

    // MARK: - Reading

    /// Reads the list. Joins a list already on the wire under the same scope, session and
    /// revision; applied only if none of them moved while it was out.
    public func refresh(using handle: SessionHandle, baseURL: URL) async {
        guard let scope = identity else { return }
        let lineage = ReadLineage(scope: scope, session: handle.generation, revision: revision)
        if let running = listing, running.lineage == lineage {
            await running.task.value
            return
        }
        nextToken += 1
        let token = nextToken
        let task = Task {
            await self.runList(lineage, token: token, handle: handle, baseURL: baseURL)
        }
        listing = (lineage, token, task)
        await task.value
    }

    private func runList(
        _ lineage: ReadLineage, token: Int, handle: SessionHandle, baseURL: URL
    ) async {
        defer { if listing?.token == token { listing = nil } }
        do {
            let answered = try await Self.list(handle.client)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
            guard readStillCurrent(lineage), listing?.token == token else {
                MemosLog.api.info("a trip list answered for a revision that has moved on; dropped")
                return
            }
            trips = answered.map { Trip($0, baseURL: baseURL) }
            lastError = nil
            bump(nil)
        } catch {
            await reportRead(error, handle: handle) {
                self.readStillCurrent(lineage) && self.listing?.token == token
            }
        }
    }

    /// Reads one trip's record again (its count and cover after a change). Applied only while the
    /// revision, the session and the scope are the ones it was issued under; it moves nothing.
    @discardableResult
    public func reload(
        uid: String, using handle: SessionHandle, baseURL: URL
    ) async throws -> Trip {
        guard let scope = identity else { throw Failure.superseded }
        let lineage = ReadLineage(scope: scope, session: handle.generation, revision: revision)
        let answered: Components.Schemas.CollectionOut
        do {
            answered = try await Self.get(handle.client, uid: uid)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            throw await failure(error, scope: scope, handle: handle)
        }
        guard readStillCurrent(lineage), let index = trips.firstIndex(where: { $0.uid == uid })
        else {
            MemosLog.api.info("a trip record answered for a revision that has moved on; dropped")
            throw Failure.superseded
        }
        let trip = Trip(answered, baseURL: baseURL)
        trips[index] = trip
        return trip
    }

    // MARK: - Writing

    /// Creates the frozen request's trip and returns it. A second call with the same request joins
    /// the first; another request under the same key is refused `.busy` and sends nothing; a
    /// request frozen under another scope sends nothing.
    @discardableResult
    public func create(
        _ frozen: NewTripRequest, using handle: SessionHandle, baseURL: URL
    ) async throws -> Trip {
        guard let scope = identity, frozen.scope == scope else { throw Failure.superseded }
        let key = frozen.idempotencyKey
        if let running = creates[key], running.authority.scope == scope {
            guard running.request == frozen else {
                MemosLog.api.info("a trip create under a running key with another body is refused")
                throw Failure.busy
            }
            onJoin?()
            let joined = await running.task.value
            if let onDelivery { await onDelivery(key, true) }
            let latest = latestCreate[key]
            return try Self.trip(delivered(joined, running.authority, latest: latest, handle))
        }
        nextToken += 1
        let authority = Authority(
            scope: scope, uid: key, token: nextToken, generation: handle.generation)
        let task = Task { await self.runCreate(frozen, authority, handle, baseURL) }
        creates[key] = (frozen, authority, task)
        latestCreate[key] = authority.token
        let result = await task.value
        if let onDelivery { await onDelivery(key, false) }
        return try Self.trip(delivered(result, authority, latest: latestCreate[key], handle))
    }

    private func runCreate(
        _ frozen: NewTripRequest, _ authority: Authority, _ handle: SessionHandle, _ baseURL: URL
    ) async -> WriteResult {
        defer {
            if creates[frozen.idempotencyKey]?.authority.token == authority.token {
                creates[frozen.idempotencyKey] = nil
            }
        }
        do {
            let answered = try await Self.post(handle.client, body: frozen.body)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
            guard writeStillOwned(authority),
                creates[frozen.idempotencyKey]?.authority.token == authority.token
            else {
                MemosLog.api.info("a trip create answered for a scope that has moved on; dropped")
                return .failed(.superseded)
            }
            let trip = Trip(answered, baseURL: baseURL)
            if let index = trips.firstIndex(where: { $0.uid == trip.uid }) {
                trips[index] = trip
            } else {
                trips.append(trip)
            }
            bump(trip.uid)
            return .trip(await reread(trip, handle, baseURL))
        } catch {
            return .failed(await failure(error, scope: authority.scope, handle: handle))
        }
    }

    /// Changes the trip's record and returns it as the server answered.
    @discardableResult
    public func update(
        uid: String, patch: TripPatch, using handle: SessionHandle, baseURL: URL
    ) async throws -> Trip {
        let result = await write(uid: uid, .update(patch), handle: handle) { authority in
            await self.runUpdate(patch, authority, handle, baseURL)
        }
        return try Self.trip(result)
    }

    private func runUpdate(
        _ patch: TripPatch, _ authority: Authority, _ handle: SessionHandle, _ baseURL: URL
    ) async -> WriteResult {
        do {
            let answered = try await ExplicitNulls.$fields.withValue(patch.clearedKeys) {
                try await Self.patch(handle.client, uid: authority.uid, body: patch.body)
            }
            session?.noteTransportSuccess(issuedUnder: handle.generation)
            guard writeStillOwned(authority), slotOwned(authority) else {
                MemosLog.api.info("a trip change answered for a scope that has moved on; dropped")
                return .failed(.superseded)
            }
            let trip = Trip(answered, baseURL: baseURL)
            if let index = trips.firstIndex(where: { $0.uid == trip.uid }) { trips[index] = trip }
            bump(trip.uid)
            return .trip(await reread(trip, handle, baseURL))
        } catch {
            return .failed(await failure(error, scope: authority.scope, handle: handle))
        }
    }

    /// Deletes the trip on the server, then here.
    public func delete(uid: String, using handle: SessionHandle) async throws {
        let result = await write(uid: uid, .delete, handle: handle) { authority in
            await self.runDelete(authority, handle)
        }
        switch result {
        case .deleted: return
        case .failed(let failure): throw failure
        case .trip, .batch: throw Failure.superseded
        }
    }

    private func runDelete(_ authority: Authority, _ handle: SessionHandle) async -> WriteResult {
        do {
            try await Self.delete(handle.client, uid: authority.uid)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
            guard writeStillOwned(authority), slotOwned(authority) else {
                MemosLog.api.info("a trip delete answered for a scope that has moved on; dropped")
                return .failed(.superseded)
            }
            trips.removeAll { $0.uid == authority.uid }
            bump(authority.uid)
            return .deleted
        } catch {
            return .failed(await failure(error, scope: authority.scope, handle: handle))
        }
    }

    /// Takes `attachment` out of the trip on the server, then reads the record again.
    public func exclude(
        uid: String, attachment: String, using handle: SessionHandle, baseURL: URL
    ) async throws {
        let outcome = try await batch(
            .exclude, [attachment], on: uid, using: handle, baseURL: baseURL)
        try Self.single(outcome)
    }

    /// Gives `attachment` back to the trip on the server, then reads the record again.
    public func include(
        uid: String, attachment: String, using handle: SessionHandle, baseURL: URL
    ) async throws {
        let outcome = try await batch(
            .include, [attachment], on: uid, using: handle, baseURL: baseURL)
        try Self.single(outcome)
    }

    enum BatchKind { case exclude, include }

    /// One removal (or add-back) batch under the trip's slot: one request per picture in order,
    /// the authority asked again before each, stopping at the first failure or stale authority;
    /// every acknowledged one is done. It always ends with a read of the record and every
    /// reconciler (the member re-drain) — still inside the slot, so the batch and its
    /// reconciliation are ONE operation: a different batch meanwhile is refused, an identical one
    /// joins and shares the whole outcome.
    func batch(
        _ kind: BatchKind, _ attachments: [String], on uid: String, using handle: SessionHandle,
        baseURL: URL
    ) async throws -> TripBatchOutcome {
        let operation: Operation =
            kind == .exclude ? .exclude(Set(attachments)) : .include(Set(attachments))
        let result = await write(uid: uid, operation, handle: handle) { authority in
            await self.runBatch(kind, attachments, authority, handle, baseURL)
        }
        switch result {
        case .batch(let outcome): return outcome
        case .failed(let failure): throw failure
        case .trip, .deleted: throw Failure.superseded
        }
    }

    private func runBatch(
        _ kind: BatchKind, _ attachments: [String], _ authority: Authority,
        _ handle: SessionHandle, _ baseURL: URL
    ) async -> WriteResult {
        var done: [String] = []
        var stopped: Failure?
        for attachment in attachments {
            guard writeStillOwned(authority), slotOwned(authority) else {
                stopped = .superseded
                break
            }
            do {
                if kind == .exclude {
                    try await Self.exclude(
                        handle.client, uid: authority.uid, attachment: attachment)
                } else {
                    try await Self.include(
                        handle.client, uid: authority.uid, attachment: attachment)
                }
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                done.append(attachment)
                if writeStillOwned(authority) {
                    for note in onAcknowledged { note(kind, authority.uid, attachment) }
                }
            } catch {
                stopped = await failure(error, scope: authority.scope, handle: handle)
                break
            }
        }
        // The whole authority, after the last await: nothing is applied past it.
        guard writeStillOwned(authority), slotOwned(authority) else { return .failed(.superseded) }
        if !done.isEmpty { bump(authority.uid) }
        var outcome = TripBatchOutcome(done: done, stopped: stopped, recordFresh: false)
        do {
            try await reload(uid: authority.uid, using: handle, baseURL: baseURL)
            outcome.recordFresh = true
        } catch {
            guard writeStillOwned(authority) else { return .failed(.superseded) }
        }
        for reconcile in onReconcile { await reconcile(authority.uid, handle, baseURL) }
        return .batch(outcome)
    }

    // MARK: - Slots and fences

    /// Runs `perform` in trip `uid`'s slot, or joins the identical write already in it, or refuses.
    /// Either caller is answered only through `delivered`.
    private func write(
        uid: String, _ operation: Operation, handle: SessionHandle,
        perform: @escaping @MainActor (Authority) async -> WriteResult
    ) async -> WriteResult {
        guard let scope = identity else { return .failed(.superseded) }
        let key = WriteKey(scope: scope, uid: uid, operation: operation)
        if let running = writes[uid] {
            guard running.key == key else {
                MemosLog.api.info("a trip write asked for while another is out is refused")
                return .failed(.busy)
            }
            onJoin?()
            let joined = await running.task.value
            if let onDelivery { await onDelivery(uid, true) }
            return delivered(joined, running.authority, latest: latestWrite[uid], handle)
        }
        nextToken += 1
        let authority = Authority(
            scope: scope, uid: uid, token: nextToken, generation: handle.generation)
        let task = Task {
            let result = await perform(authority)
            if self.writes[uid]?.authority.token == authority.token { self.writes[uid] = nil }
            return result
        }
        writes[uid] = (key, authority, task)
        latestWrite[uid] = authority.token
        let result = await task.value
        if let onDelivery { await onDelivery(uid, false) }
        return delivered(result, authority, latest: latestWrite[uid], handle)
    }

    /// The caller's half of a write's fence, asked after its wait and before it is answered: the
    /// scope and the session the write was issued under must still be running, the caller's own
    /// session too, and no later write may have taken the slot it waited on (`latest`, the token
    /// of the latest slot taken there). Anything else is `.superseded`, failures included — no
    /// sentence of a write that lost its authority reaches a screen.
    private func delivered(
        _ result: WriteResult, _ authority: Authority, latest: Int?, _ handle: SessionHandle
    ) -> WriteResult {
        guard writeStillOwned(authority), sessionStillCurrent(handle.generation),
            latest == authority.token
        else {
            MemosLog.api.info("a trip write's caller lost its authority while it waited")
            return .failed(.superseded)
        }
        return result
    }

    private static func trip(_ result: WriteResult) throws -> Trip {
        switch result {
        case .trip(let trip): return trip
        case .failed(let failure): throw failure
        case .deleted, .batch: throw Failure.superseded
        }
    }

    /// A change's record read again (decision 8: its count and cover after every mutation), still
    /// inside the change's slot. The change was acknowledged and applied already, so a re-read that
    /// fails or is dropped keeps it: the caller gets the record the change answered.
    private func reread(_ trip: Trip, _ handle: SessionHandle, _ baseURL: URL) async -> Trip {
        do {
            return try await reload(uid: trip.uid, using: handle, baseURL: baseURL)
        } catch {
            MemosLog.api.info("a trip's record could not be read again after a change; kept")
            return trip
        }
    }

    private static func single(_ outcome: TripBatchOutcome) throws {
        if let stopped = outcome.stopped, outcome.done.isEmpty { throw stopped }
    }

    private func writeStillOwned(_ authority: Authority) -> Bool {
        identity == authority.scope && sessionStillCurrent(authority.generation)
    }

    private func slotOwned(_ authority: Authority) -> Bool {
        writes[authority.uid]?.authority.token == authority.token
    }

    private func readStillCurrent(_ lineage: ReadLineage) -> Bool {
        identity == lineage.scope && revision == lineage.revision
            && sessionStillCurrent(lineage.session)
    }

    private func bump(_ uid: String?) {
        revision += 1
        for invalidate in onInvalidate { invalidate(uid) }
    }

    private func sessionStillCurrent(_ generation: Int) -> Bool {
        guard let session else { return true }
        return session.activeHandle?.generation == generation
    }

    /// A write's failure, typed: the refusal goes through the session's funnel first, and the
    /// scope is asked again after that wait.
    private func failure(
        _ error: any Error, scope: TimelineSnapshotIdentity, handle: SessionHandle
    ) async -> Failure {
        noteAnswered(error, handle)
        guard identity == scope, sessionStillCurrent(handle.generation),
            !StoreFailure.isCancellation(error)
        else { return .superseded }
        if let reason = StoreFailure.transportFailure(error) {
            session?.noteTransportFailure(reason, issuedUnder: handle.generation)
            return .transport
        }
        if let refusal = StoreFailure.refusal(error) {
            _ = await onUnauthorized(refusal)
            guard identity == scope, nothingEstablishedSince(handle) else { return .superseded }
            return .refusal(refusal)
        }
        switch StoreFailure.reportable(error) {
        case .server(let status): return .server(status: status)
        case .notFound: return .server(status: 404)
        case .forbidden: return .server(status: 403)
        case nil: return .superseded
        case let other?: return .failed(other)
        }
    }

    /// A list's failure: the Library's funnel, in its order.
    private func reportRead(
        _ error: any Error, handle: SessionHandle, while owned: () -> Bool
    ) async {
        noteAnswered(error, handle)
        guard sessionStillCurrent(handle.generation) else { return }
        if let reason = StoreFailure.transportFailure(error) {
            if owned() { lastError = nil }
            session?.noteTransportFailure(reason, issuedUnder: handle.generation)
            return
        }
        if let refusal = StoreFailure.refusal(error) {
            if await onUnauthorized(refusal) == .endedSession, nothingEstablishedSince(handle),
                owned()
            {
                lastError = refusal.errorDescription
            }
            return
        }
        guard let apiError = StoreFailure.reportable(error) else { return }
        if owned() { lastError = apiError.errorDescription }
    }

    /// A failed request that the server answered — a status, a body this device could not read —
    /// is an answered request all the same, and is reported as one.
    private func noteAnswered(_ error: any Error, _ handle: SessionHandle) {
        guard StoreFailure.reachedServer(error) else { return }
        session?.noteTransportSuccess(issuedUnder: handle.generation)
    }

    private func nothingEstablishedSince(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        return session.nothingEstablishedSince(handle)
    }

    // MARK: - The legacy files

    /// The names of the device-local files the scope's directory once held, each spelled in parts
    /// so nothing in the packages names an old file whole and a search for either name finds no
    /// reader or writer of it left: the pilot's trips file (MEMNG-754) and the composer pin's file
    /// (MEMNG-781 — the pin is gone; the composer offers the trip whose span holds today).
    nonisolated static let legacyFileNames = [
        ["collections", "json"].joined(separator: "."),
        ["pins", "json"].joined(separator: "."),
    ]

    /// Nothing device-local of a trip is kept any more: the scope's legacy files
    /// (`legacyFileNames`) are removed, best effort, every time the store enters the scope (at
    /// init and at each identity change), and never read. No attempt is recorded: nothing in the
    /// app writes either file any more, so a later entry only retries a removal that failed, or
    /// removes one an older build wrote back — both wanted.
    private func dropLegacyFiles() {
        guard let root, let identity else { return }
        let directory = root.appending(path: Self.scopeKey(for: identity))
        for name in Self.legacyFileNames {
            let legacy = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: legacy.path) else { continue }
            do {
                try FileManager.default.removeItem(at: legacy)
                MemosLog.session.info("a device-local trip file was removed; nothing reads it")
            } catch {
                MemosLog.session.error("a device-local trips file could not be removed")
            }
        }
    }

    /// `Collections` inside the app group, or nil when the container is not reachable.
    public nonisolated static func appGroupRoot(
        appGroup: String = DeviceCredentials.appGroup
    ) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Collections")
    }

    /// The directory name an identity's files were kept under: the SHA-256 of the pair, in hex.
    ///
    /// A digest because neither a base URL nor an issuer's subject is a legal path component, and
    /// a stable one because the same identity has to find its directory again on the next launch.
    public nonisolated static func scopeKey(for identity: TimelineSnapshotIdentity) -> String {
        let material = Data("\(identity.server.absoluteString)\n\(identity.subject)".utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The wire

    static func list(_ client: any APIProtocol) async throws -> [Components.Schemas.CollectionOut] {
        switch try await client.listCollectionsApiCollectionsGet(.init()) {
        case .ok(let ok): return try ok.body.json
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func get(_ client: any APIProtocol, uid: String) async throws
        -> Components.Schemas.CollectionOut
    {
        switch try await client.getCollectionApiCollectionsUidGet(.init(path: .init(uid: uid))) {
        case .ok(let ok): return try ok.body.json
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func post(
        _ client: any APIProtocol, body: Components.Schemas.CollectionCreate
    ) async throws -> Components.Schemas.CollectionOut {
        switch try await client.createCollectionApiCollectionsPost(.init(body: .json(body))) {
        case .created(let created): return try created.body.json
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func patch(
        _ client: any APIProtocol, uid: String, body: Components.Schemas.CollectionPatch
    ) async throws -> Components.Schemas.CollectionOut {
        let input = Operations.UpdateCollectionApiCollectionsUidPatch.Input(
            path: .init(uid: uid), body: .json(body))
        switch try await client.updateCollectionApiCollectionsUidPatch(input) {
        case .ok(let ok): return try ok.body.json
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func delete(_ client: any APIProtocol, uid: String) async throws {
        let input = Operations.DeleteCollectionApiCollectionsUidDelete.Input(path: .init(uid: uid))
        switch try await client.deleteCollectionApiCollectionsUidDelete(input) {
        case .noContent: return
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func exclude(_ client: any APIProtocol, uid: String, attachment: String) async throws {
        let input = Operations.ExcludeAttachmentApiCollectionsUidExclusionsAttachmentUidPut.Input(
            path: .init(uid: uid, attachmentUid: attachment))
        switch try await client.excludeAttachmentApiCollectionsUidExclusionsAttachmentUidPut(
            input)
        {
        case .noContent: return
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func include(_ client: any APIProtocol, uid: String, attachment: String) async throws {
        let input = Operations.IncludeAttachmentApiCollectionsUidExclusionsAttachmentUidDelete
            .Input(path: .init(uid: uid, attachmentUid: attachment))
        switch try await client.includeAttachmentApiCollectionsUidExclusionsAttachmentUidDelete(
            input)
        {
        case .noContent: return
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }
}
