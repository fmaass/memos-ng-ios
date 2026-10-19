import Foundation
import MemosAPI

/// What the server says about one file beyond what the page it was opened on carries: its size,
/// and its capture fields as the file's own record holds them.
///
/// A projection of `AttachmentMeta` and nothing more. It holds no URL on purpose: the Info sheet
/// reads facts from it, and nothing that draws a picture may be handed one from here.
public struct AttachmentFacts: Sendable, Equatable {
    public var uid: String
    public var mime: String
    /// The stored file's size in bytes, as the server measured it.
    public var size: Int
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var captureInstant: Date?
    public var captureCivil: String?
    public var captureSource: String?

    public init(
        uid: String,
        mime: String,
        size: Int,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        captureInstant: Date? = nil,
        captureCivil: String? = nil,
        captureSource: String? = nil
    ) {
        self.uid = uid
        self.mime = mime
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.captureInstant = captureInstant
        self.captureCivil = captureCivil
        self.captureSource = captureSource
    }
}

/// The two reads the opened-picture viewer's Info sheet makes: the memo a page hangs on, when the
/// page did not arrive with it, and the file's own record.
///
/// **Only on demand.** Nothing here is read because a page is on screen; the sheet asks when it
/// opens, and a viewer nobody asks about sends nothing.
///
/// **The memo, once per uid.** A memo found is kept for the life of this store — one store per
/// viewer — so opening the sheet again, or on another picture of the same memo, sends nothing. A
/// second ask while the first is in the air JOINS it: one request on the wire. A read that failed
/// keeps nothing, so the next open asks again.
///
/// **The file's record, once per open.** Its size does not change, but its readiness can, so each
/// open asks once; an ask while one for the same file is in the air joins it.
///
/// **Fenced by generation.** Every answer is judged against the generation and the session handle
/// that ISSUED it: an identity change bumps the generation and clears what is held, and an answer
/// that outlived it lands nowhere. A refusal goes to the session's one decision rule
/// (`onUnauthorized`), as every other store's does.
@MainActor
@Observable
public final class MediaContextStore {
    public enum Lookup<Value: Equatable & Sendable>: Equatable, Sendable {
        case found(Value)
        case unavailable
    }

    public private(set) var memos: [String: Lookup<Memo>] = [:]
    public private(set) var facts: [String: Lookup<AttachmentFacts>] = [:]

    private var generation = 0
    private var memoFlights: [String: Flight] = [:]
    private var factFlights: [String: Flight] = [:]
    private var nextToken = 0
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    private var session: (any SessionReporting)?

    private struct Flight {
        let token: Int
        let generation: Int
        let task: Task<Void, Never>
    }

    public init(
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.onUnauthorized = onUnauthorized
    }

    public func reports(to session: any SessionReporting) { self.session = session }

    /// The memo held for `uid`, or nil when none was found (yet).
    public func memo(_ uid: String) -> Memo? {
        if case .found(let memo) = memos[uid] { return memo }
        return nil
    }

    /// The file record held for `uid`, or nil.
    public func facts(of uid: String) -> AttachmentFacts? {
        if case .found(let facts) = facts[uid] { return facts }
        return nil
    }

    /// Reads the memo `uid` unless it is already held; joins a read already in the air.
    public func loadMemo(uid: String, using handle: SessionHandle, baseURL: URL) async {
        if case .found = memos[uid] { return }
        if let running = memoFlights[uid], running.generation == generation {
            await running.task.value
            return
        }
        guard sessionStillCurrent(handle) else { return }
        nextToken += 1
        let token = nextToken
        let issued = generation
        let task = Task { await self.runMemo(uid, issued, token, handle, baseURL) }
        memoFlights[uid] = Flight(token: token, generation: issued, task: task)
        await task.value
    }

    /// Reads the record of file `uid` once; joins a read already in the air for it.
    public func loadFacts(uid: String, using handle: SessionHandle, baseURL: URL) async {
        if let running = factFlights[uid], running.generation == generation {
            await running.task.value
            return
        }
        guard sessionStillCurrent(handle) else { return }
        nextToken += 1
        let token = nextToken
        let issued = generation
        let task = Task { await self.runFacts(uid, issued, token, handle) }
        factFlights[uid] = Flight(token: token, generation: issued, task: task)
        await task.value
    }

    /// The account changed: nothing held is about the reader any more, and nothing in the air may
    /// land.
    public func sessionIdentityChanged() {
        generation += 1
        memos = [:]
        facts = [:]
        memoFlights = [:]
        factFlights = [:]
    }

    private func runMemo(
        _ uid: String, _ issued: Int, _ token: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        defer { if memoFlights[uid]?.token == token { memoFlights[uid] = nil } }
        do {
            let memo = try await Self.memo(handle.client, uid: uid, baseURL: baseURL)
            guard issued == generation, sessionStillCurrent(handle) else {
                MemosLog.api.info("a viewer's memo answered for a session that has gone; dropped")
                return
            }
            memos[uid] = .found(memo)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else { return }
            if await settled(error, issuedUnder: handle) { memos[uid] = .unavailable }
        }
    }

    private func runFacts(
        _ uid: String, _ issued: Int, _ token: Int, _ handle: SessionHandle
    ) async {
        defer { if factFlights[uid]?.token == token { factFlights[uid] = nil } }
        do {
            let read = try await Self.facts(handle.client, uid: uid)
            guard issued == generation, sessionStillCurrent(handle) else {
                MemosLog.api.info("a file record answered for a session that has gone; dropped")
                return
            }
            facts[uid] = .found(read)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else { return }
            if await settled(error, issuedUnder: handle), facts[uid] == nil {
                facts[uid] = .unavailable
            }
        }
    }

    /// Routes a failed read and says whether it is an ANSWER worth showing as "unavailable": a
    /// cancellation is not, and nor is anything about a session that has gone.
    private func settled(_ error: any Error, issuedUnder handle: SessionHandle) async -> Bool {
        if let refusal = StoreFailure.refusal(error) {
            _ = await onUnauthorized(refusal)
            return false
        }
        guard sessionStillCurrent(handle) else { return false }
        if let failure = StoreFailure.transportFailure(error) {
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            return true
        }
        return StoreFailure.reportable(error) != nil
    }

    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }

    static func memo(_ client: any APIProtocol, uid: String, baseURL: URL) async throws -> Memo {
        switch try await client.getMemoApiMemosUidGet(.init(path: .init(uid: uid))) {
        case .ok(let ok): return Memo(try ok.body.json, baseURL: baseURL)
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        }
    }

    static func facts(_ client: any APIProtocol, uid: String) async throws -> AttachmentFacts {
        let input = Operations.AttachmentMetaApiAttachmentsUidGet.Input(path: .init(uid: uid))
        switch try await client.attachmentMetaApiAttachmentsUidGet(input) {
        case .ok(let ok):
            let meta = try ok.body.json
            return AttachmentFacts(
                uid: meta.uid,
                mime: meta.mime,
                size: meta.size,
                width: meta.width,
                height: meta.height,
                duration: meta.duration,
                captureInstant: meta.captureInstant,
                captureCivil: meta.captureCivil,
                captureSource: meta.captureSource
            )
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        }
    }
}
