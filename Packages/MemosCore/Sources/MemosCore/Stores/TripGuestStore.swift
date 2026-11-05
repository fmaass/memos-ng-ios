import Foundation
import MemosAPI

/// One collection's guest passes, the devices that walked through them and the pictures they
/// brought (memos-ng 2.9.0, Trip Pass): Invite Guests, the Guests list and the Guest Uploads inbox.
///
/// Every signed-in member may issue, end and moderate every pass of every collection — the server
/// grants it to anyone who may edit the collection — so nothing here asks who the owner is. A
/// status the server refuses with is said as a sentence (`Failure`), never assumed away.
///
/// Its fences:
///
/// * **one write at a time, joined or refused.** Issuing, ending a pass, revoking a device and
///   each moderation take the store's one write slot. A second call of the IDENTICAL operation
///   while it is on the wire joins it and gets its answer — a double tap is one request; any other
///   write meanwhile is refused with `Failure.busy` and sends nothing;
/// * **every write is read back.** Once a write has landed the store reads again what it changed
///   (the passes, a pass's devices, the uploads), inside the same slot, so the screen ends on what
///   the server holds rather than on what the call was expected to do;
/// * **a read asked before a write cannot undo it.** `epoch` moves as each write starts and as it
///   lands; a read lands only under the epoch it was issued under, and a read already on the wire
///   is joined only while that epoch still stands — the read-back after a write is a new request;
/// * **every answer is judged against the identity that issued it.** `sessionIdentityChanged`
///   moves the generation, and the session's own handle generation is asked as well; the guest URL
///   an issue returned is readable only under both;
/// * a refused credential goes to `onUnauthorized` as the one typed `CredentialRefusal`, through
///   the shared `StoreFailure` funnel.
///
/// The guest URL carries the pass's secret. It is held in memory for the Invite sheet alone —
/// never written anywhere, never logged — and dropped by `dismissIssued` or an identity change.
@MainActor
@Observable
public final class TripGuestStore {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// Another change to this trip's guests is on the wire; nothing was sent.
        case busy
        /// The account changed while the request was out; nothing was applied.
        case superseded
        /// The server could not be reached; the session's banner says so.
        case transport
        /// The trip has no tag, so a guest's picture taken outside its dates could not join it.
        case tripHasNoTag
        /// The pass, or the device, was already ended.
        case alreadyEnded
        /// The server would not let this account do it.
        case forbidden
        case server(status: Int)
        case failed(APIError)

        public var errorDescription: String? {
            switch self {
            case .busy: "Another change to this trip's guests is still being saved."
            case .superseded, .transport: nil
            case .tripHasNoTag:
                "Guests can be invited to a trip with a tag: give this trip one first."
            case .alreadyEnded: "This was already ended."
            case .forbidden: "This account may not manage this trip's guests."
            case .server(let status): APIError.fromStatus(status).errorDescription
            case .failed(let error): error.errorDescription
            }
        }
    }

    /// The collection whose guests these are.
    public let collectionUid: String
    /// The collection's passes, newest first, revoked ones included; nil until a list has landed.
    public private(set) var passes: [TripPass]?
    /// Each pass's devices as last listed, keyed by the pass's uid.
    public private(set) var devices: [String: [TripPassDevice]] = [:]
    /// Every picture that came in through any of the passes, newest first; nil until listed.
    public private(set) var contributions: [TripContribution]?
    /// What the last read could not do, or nil.
    public private(set) var notice: String?

    /// The pass this store issued, with its guest URL — only under the identity it was issued
    /// for, judged here as the screen reads, because the session can be replaced underneath the
    /// sheet before the sheet goes away.
    public var issued: IssuedTripPass? {
        guard let held = heldIssued, held.generation == generation,
            sessionStillCurrent(held.session)
        else { return nil }
        return held.pass
    }

    /// Whether a write is on the wire. The controls go quiet; the store is what refuses.
    public var isWriting: Bool { write != nil }

    /// The picture behind a contribution, read for its thumbnail, or nil until it is.
    public func picture(for uid: String) -> MemoAttachment? { pictures[uid]?.attachment }

    /// The name that picture's file was uploaded under, read with it; nil until it is, and nil
    /// when the server has none.
    public func filename(for uid: String) -> String? { pictures[uid]?.filename ?? nil }

    enum Write: Hashable, Sendable {
        case issue(TripPassDraft)
        case endPass(String)
        case revokeDevice(pass: String, device: String)
        case moderate(TripModeration, Set<String>)
    }

    enum Landed: Sendable {
        case issued(IssuedTripPass)
        case done
        case moderated(TripModerationOutcome)
    }

    enum Read: Hashable {
        case passes
        case devices(String)
        case contributions
    }

    private var heldIssued: (pass: IssuedTripPass, generation: Int, session: Int)?
    /// Moved by every `dismissIssued`: an issue that was out across one holds nothing.
    private var dismissals = 0
    private var pictures: [String: (attachment: MemoAttachment, filename: String?)] = [:]
    private var picturesAsked: Set<String> = []
    private var write: (operation: Write, token: Int, task: Task<Landed, any Error>)?
    private var reads: [Read: (token: Int, generation: Int, epoch: Int, task: Task<Void, Never>)] =
        [:]
    private var generation = 0
    private var epoch = 0
    private var nextToken = 0
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    /// Told what each Guest Uploads read listed: the trip re-reads its members when one of them
    /// is newer than its drain (MEMNG-1160).
    private let onContributions: @MainActor ([TripContribution]) async -> Void
    private var session: (any SessionReporting)?

    public init(
        collectionUid: String,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded },
        onContributions: @escaping @MainActor ([TripContribution]) async -> Void = { _ in }
    ) {
        self.collectionUid = collectionUid
        self.onUnauthorized = onUnauthorized
        self.onContributions = onContributions
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    // MARK: - Reads

    /// Lists the collection's passes.
    public func loadPasses(using handle: SessionHandle) async {
        await read(.passes, using: handle) { client in
            let listed = try await Self.listPasses(client, collection: self.collectionUid)
            return { $0.passes = listed }
        }
    }

    /// Lists the devices of pass `uid`.
    public func loadDevices(of uid: String, using handle: SessionHandle) async {
        await read(.devices(uid), using: handle) { client in
            let listed = try await Self.listDevices(client, pass: uid)
            return { $0.devices[uid] = listed }
        }
    }

    /// Lists the passes again, then every picture each of them brought, as one answer: the inbox
    /// is never shown half of one list and half of the next.
    public func loadContributions(using handle: SessionHandle) async {
        await read(.contributions, using: handle) { client in
            let listed = try await Self.listPasses(client, collection: self.collectionUid)
            var found: [TripContribution] = []
            for pass in listed {
                found += try await Self.listContributions(client, pass: pass.uid)
            }
            let merged = found.sorted { $0.createdAt > $1.createdAt }
            return {
                $0.passes = listed
                $0.contributions = merged
            }
        }
        guard sessionStillCurrent(handle), let listed = contributions else { return }
        await onContributions(listed)
    }

    /// Reads the record of picture `uid` for its thumbnail and its row's file name, once per
    /// identity. A failure leaves the row without either; only a refused credential is reported.
    public func loadPicture(_ uid: String, using handle: SessionHandle, baseURL: URL) async {
        guard pictures[uid] == nil, !picturesAsked.contains(uid), sessionStillCurrent(handle)
        else { return }
        picturesAsked.insert(uid)
        let issued = generation
        do {
            let picture = try await TripMemberStore.record(
                handle.client, uid: uid, baseURL: baseURL)
            guard issued == generation, sessionStillCurrent(handle) else { return }
            pictures[uid] = picture
        } catch {
            guard issued == generation else { return }
            picturesAsked.remove(uid)
            if StoreFailure.refusal(error) != nil { await report(error, issuedUnder: handle) }
        }
    }

    /// One read, joined while the same read of the same generation AND epoch is on the wire, and
    /// applied only while both still stand when it lands.
    private func read(
        _ key: Read, using handle: SessionHandle,
        _ fetch:
            @escaping @MainActor (any APIProtocol) async throws ->
            @MainActor (TripGuestStore) -> Void
    ) async {
        if let running = reads[key], running.generation == generation, running.epoch == epoch {
            await running.task.value
            return
        }
        guard sessionStillCurrent(handle) else { return }
        nextToken += 1
        let token = nextToken
        let issued = (generation: generation, epoch: epoch)
        let task = Task {
            defer { if self.reads[key]?.token == token { self.reads[key] = nil } }
            let apply: @MainActor (TripGuestStore) -> Void
            do {
                apply = try await fetch(handle.client)
            } catch {
                guard issued.generation == self.generation else { return }
                let failure = await self.failure(error, issuedUnder: handle)
                // Under the same fence as an answer: a failure of a read a later one has
                // overtaken must not stand over what that later read said.
                if issued.generation == self.generation, issued.epoch == self.epoch,
                    let sentence = failure.errorDescription
                {
                    self.notice = sentence
                }
                return
            }
            guard issued.generation == self.generation, issued.epoch == self.epoch,
                self.sessionStillCurrent(handle)
            else {
                MemosLog.api.info(
                    "a guest list answered after a change or another account; dropped")
                return
            }
            apply(self)
            self.notice = nil
            self.session?.noteTransportSuccess(issuedUnder: handle.generation)
        }
        reads[key] = (token, issued.generation, issued.epoch, task)
        await task.value
    }

    // MARK: - Writes

    /// Issues a pass for the collection. The answer is the only time its guest URL is ever seen;
    /// it is held for `issued`, and the passes are read back.
    @discardableResult
    public func issue(_ draft: TripPassDraft, using handle: SessionHandle) async throws
        -> IssuedTripPass
    {
        let landed = try await perform(.issue(draft), using: handle) { client in
            .issued(try await Self.issue(client, collection: self.collectionUid, draft: draft))
        }
        guard case .issued(let made) = landed else { throw Failure.superseded }
        return made
    }

    /// Ends pass `uid` for every device that holds it. Its devices and pictures stay readable.
    public func endPass(_ uid: String, using handle: SessionHandle) async throws {
        _ = try await perform(.endPass(uid), using: handle) { client in
            try await Self.revokePass(client, pass: uid)
            return .done
        }
    }

    /// Ends one device of pass `pass`; the pass's other devices keep working.
    public func revokeDevice(_ device: String, of pass: String, using handle: SessionHandle)
        async throws
    {
        _ = try await perform(.revokeDevice(pass: pass, device: device), using: handle) { client in
            try await Self.revokeDevice(client, pass: pass, device: device)
            return .done
        }
    }

    /// Hides, unhides or removes the chosen pictures, addressed to the pass each came through,
    /// then reads the inbox back. Pictures the inbox does not list are not sent.
    @discardableResult
    public func moderate(
        _ action: TripModeration, _ uids: Set<String>, using handle: SessionHandle
    ) async throws -> TripModerationOutcome {
        let byPass = Self.grouped(uids, in: contributions ?? [])
        guard !byPass.isEmpty else { return TripModerationOutcome() }
        let landed = try await perform(.moderate(action, uids), using: handle) { client in
            var outcome = TripModerationOutcome()
            for (pass, chosen) in byPass {
                // The route takes at most 500 uids a call.
                for start in stride(from: 0, to: chosen.count, by: 500) {
                    let chunk = Array(chosen[start..<min(start + 500, chosen.count)])
                    let answered = try await Self.moderate(
                        client, action, pass: pass, attachments: chunk)
                    outcome.applied += answered.applied
                    outcome.failed += answered.failed
                }
            }
            return .moderated(outcome)
        }
        guard case .moderated(let outcome) = landed else { throw Failure.superseded }
        return outcome
    }

    /// Drops the issued pass's guest URL from memory.
    public func dismissIssued() {
        heldIssued = nil
        dismissals += 1
    }

    /// Forgets everything read for the outgoing account and drops every answer still in flight.
    public func sessionIdentityChanged() {
        passes = nil
        devices = [:]
        contributions = nil
        notice = nil
        heldIssued = nil
        pictures = [:]
        picturesAsked = []
        reads = [:]
        write = nil
        generation += 1
    }

    /// The one write slot: the identical operation joins the one on the wire, any other is
    /// refused. The call's answer is applied, then what it changed is read again inside the slot —
    /// after a refusal the server explained too, because a moderation can fail half way through and
    /// an already-ended pass means the list on screen was out of date.
    private func perform(
        _ operation: Write, using handle: SessionHandle,
        _ call: @escaping @MainActor (any APIProtocol) async throws -> Landed
    ) async throws -> Landed {
        if let running = write {
            guard running.operation == operation else { throw Failure.busy }
            let joined = generation
            let landed = try await running.task.value
            guard joined == generation, sessionStillCurrent(handle) else {
                throw Failure.superseded
            }
            return landed
        }
        guard sessionStillCurrent(handle) else { throw Failure.superseded }
        nextToken += 1
        let token = nextToken
        let issued = generation
        let dismissedAtIssue = dismissals
        epoch += 1
        let task = Task<Landed, any Error> {
            defer { if self.write?.token == token { self.write = nil } }
            let landed: Landed
            do {
                landed = try await call(handle.client)
            } catch {
                guard issued == self.generation else { throw Failure.superseded }
                let failure = await self.failure(error, issuedUnder: handle)
                if Self.readsBack(after: failure), issued == self.generation {
                    self.epoch += 1
                    await self.readBack(operation, using: handle)
                }
                throw failure
            }
            guard issued == self.generation, self.sessionStillCurrent(handle) else {
                throw Failure.superseded
            }
            self.epoch += 1
            // A sheet dismissed while the POST was out asked for the URL to be gone; the answer
            // that outlived it does not bring it back.
            if case .issued(let made) = landed, dismissedAtIssue == self.dismissals {
                self.heldIssued = (made, issued, handle.generation)
            }
            if case .endPass(let uid) = operation, self.heldIssued?.pass.pass.uid == uid {
                self.heldIssued = nil
            }
            self.session?.noteTransportSuccess(issuedUnder: handle.generation)
            await self.readBack(operation, using: handle)
            // The read-back is a suspension: an account that changed during it owns nothing this
            // write answered, and above all not the guest URL.
            guard issued == self.generation, self.sessionStillCurrent(handle) else {
                throw Failure.superseded
            }
            return landed
        }
        write = (operation, token, task)
        let landed = try await task.value
        // The write's own last check ran before it returned, and each caller resumes later as a
        // job of its own: an account that changed in between owns nothing it answered.
        guard issued == generation, sessionStillCurrent(handle) else { throw Failure.superseded }
        return landed
    }

    private func readBack(_ operation: Write, using handle: SessionHandle) async {
        switch operation {
        case .issue: await reread(.passes, using: handle)
        case .endPass(let uid):
            await reread(.passes, using: handle)
            await reread(.devices(uid), using: handle)
        case .revokeDevice(let pass, _):
            await reread(.devices(pass), using: handle)
            await reread(.passes, using: handle)
        case .moderate: await reread(.contributions, using: handle)
        }
    }

    private func reread(_ key: Read, using handle: SessionHandle) async {
        switch key {
        case .passes: await loadPasses(using: handle)
        case .devices(let uid): await loadDevices(of: uid, using: handle)
        case .contributions: await loadContributions(using: handle)
        }
    }

    /// Whether a failed write still changed, or proved stale, what is on screen: an answer the
    /// server gave about the thing itself. Not a transport failure, a credential the session
    /// handles, or an answer for an account that has gone.
    static func readsBack(after failure: Failure) -> Bool {
        switch failure {
        case .alreadyEnded, .server: true
        case .busy, .superseded, .transport, .tripHasNoTag, .forbidden, .failed: false
        }
    }

    /// The chosen uids grouped by the pass each came through, every group in the inbox's order.
    static func grouped(_ uids: Set<String>, in listed: [TripContribution]) -> [(String, [String])]
    {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for row in listed where uids.contains(row.attachmentUid) {
            if groups[row.passUid] == nil { order.append(row.passUid) }
            groups[row.passUid, default: []].append(row.attachmentUid)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    // MARK: - Failures

    /// What a failed call says once the funnel has heard it: nothing for an answer the session
    /// has moved past or a transport failure (the session's banner says that one), the server's
    /// sentence otherwise.
    private func failure(_ error: any Error, issuedUnder handle: SessionHandle) async -> Failure {
        await report(error, issuedUnder: handle)
        guard sessionStillCurrent(handle), !StoreFailure.isCancellation(error) else {
            return .superseded
        }
        if StoreFailure.transportFailure(error) != nil { return .transport }
        switch StoreFailure.reportable(error) {
        case .server(409): return .tripHasNoTag
        case .server(410): return .alreadyEnded
        case .server(let status): return .server(status: status)
        case .notFound: return .server(status: 404)
        case .forbidden: return .forbidden
        case nil: return .superseded
        case let other?: return .failed(other)
        }
    }

    private func report(_ error: any Error, issuedUnder handle: SessionHandle) async {
        if let refusal = StoreFailure.refusal(error) {
            _ = await onUnauthorized(refusal)
            return
        }
        guard sessionStillCurrent(handle) else { return }
        if let failure = StoreFailure.transportFailure(error) {
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
        }
    }

    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        sessionStillCurrent(handle.generation)
    }

    private func sessionStillCurrent(_ issued: Int) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == issued
    }

    // MARK: - The wire

    static func listPasses(_ client: any APIProtocol, collection: String) async throws
        -> [TripPass]
    {
        let response = try await client.listPassesApiCollectionsUidPassesGet(
            .init(path: .init(uid: collection)))
        switch response {
        case .ok(let ok): return try ok.body.json.map(TripPass.init)
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func issue(_ client: any APIProtocol, collection: String, draft: TripPassDraft)
        async throws -> IssuedTripPass
    {
        let body = Components.Schemas.PassCreate(
            expiresAt: draft.expiresAt, label: draft.sentLabel ?? draft.label,
            maxDevices: draft.maxDevices,
            scope: Components.Schemas.PassCreate.ScopePayload(rawValue: draft.scope.rawValue))
        let response = try await client.issuePassApiCollectionsUidPassesPost(
            .init(path: .init(uid: collection), body: .json(body)))
        switch response {
        case .created(let created):
            let issued = try created.body.json
            guard let url = URL(string: issued.url) else {
                throw APIError.decoding(description: "the issued pass carries no usable URL")
            }
            return IssuedTripPass(pass: TripPass(issued.pass), url: url)
        case .notFound: throw APIError.notFound
        case .conflict: throw APIError.server(status: 409)
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func revokePass(_ client: any APIProtocol, pass: String) async throws {
        let response = try await client.revokePassApiPassesUidDelete(
            .init(path: .init(uid: pass)))
        switch response {
        case .ok: return
        case .notFound: throw APIError.notFound
        case .gone: throw APIError.server(status: 410)
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func listDevices(_ client: any APIProtocol, pass: String) async throws
        -> [TripPassDevice]
    {
        let response = try await client.listDevicesApiPassesUidDevicesGet(
            .init(path: .init(uid: pass)))
        switch response {
        case .ok(let ok): return try ok.body.json.map(TripPassDevice.init)
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func revokeDevice(_ client: any APIProtocol, pass: String, device: String)
        async throws
    {
        let response = try await client.revokeDeviceApiPassesUidDevicesDeviceUidDelete(
            .init(path: .init(uid: pass, deviceUid: device)))
        switch response {
        case .ok: return
        case .notFound: throw APIError.notFound
        case .gone: throw APIError.server(status: 410)
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func listContributions(_ client: any APIProtocol, pass: String) async throws
        -> [TripContribution]
    {
        let response = try await client.listContributionsApiPassesUidContributionsGet(
            .init(path: .init(uid: pass)))
        switch response {
        case .ok(let ok): return try ok.body.json.map { TripContribution($0, pass: pass) }
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }

    static func moderate(
        _ client: any APIProtocol, _ action: TripModeration, pass: String, attachments: [String]
    ) async throws -> TripModerationOutcome {
        let body = Components.Schemas.ContributionSelection(attachmentUids: attachments)
        let results: [Components.Schemas.ModerationResult]
        switch action {
        case .hide:
            let response = try await client.hideContributionsApiPassesUidContributionsHidePost(
                .init(path: .init(uid: pass), body: .json(body)))
            switch response {
            case .ok(let ok): results = try ok.body.json.results
            case .notFound: throw APIError.notFound
            case .unprocessableContent: throw APIError.server(status: 422)
            case .serviceUnavailable: throw APIError.fromStatus(503)
            case .undocumented(let status, _): throw APIError.fromStatus(status)
            default: throw StoreFailure.documentedRefusal
            }
        case .unhide:
            let response = try await client.unhideContributionsApiPassesUidContributionsUnhidePost(
                .init(path: .init(uid: pass), body: .json(body)))
            switch response {
            case .ok(let ok): results = try ok.body.json.results
            case .notFound: throw APIError.notFound
            case .unprocessableContent: throw APIError.server(status: 422)
            case .serviceUnavailable: throw APIError.fromStatus(503)
            case .undocumented(let status, _): throw APIError.fromStatus(status)
            default: throw StoreFailure.documentedRefusal
            }
        case .remove:
            let response = try await client.removeContributionsApiPassesUidContributionsRemovePost(
                .init(path: .init(uid: pass), body: .json(body)))
            switch response {
            case .ok(let ok): results = try ok.body.json.results
            case .notFound: throw APIError.notFound
            case .unprocessableContent: throw APIError.server(status: 422)
            case .serviceUnavailable: throw APIError.fromStatus(503)
            case .undocumented(let status, _): throw APIError.fromStatus(status)
            default: throw StoreFailure.documentedRefusal
            }
        }
        let wanted: String =
            switch action {
            case .hide: "hidden"
            case .unhide: "unhidden"
            case .remove: "removed"
            }
        let applied = results.filter { $0.outcome.rawValue == wanted }.count
        return TripModerationOutcome(applied: applied, failed: results.count - applied)
    }
}
