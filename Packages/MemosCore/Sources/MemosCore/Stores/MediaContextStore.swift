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
/// **The file's record, once per OPENING.** Each time the sheet opens it takes an `Opening`
/// (`open(_:)`) and gives it back when it goes (`close(_:)`). The record is read once for that
/// opening — a second ask inside it joins the first — and the answer belongs to it alone: an
/// answer for an opening that has closed lands nowhere, a new opening never joins an old one's
/// read, and nothing starts for an opening that is no longer the live one.
///
/// **Fenced by the session that issued it.** Everything held belongs to the session generation it
/// was read under. Every ask presents its handle FIRST — before a held memo is handed back or a
/// read in the air is joined — and a handle of another generation than the one held clears it
/// all, so another account's memo is never the answer. `sessionIdentityChanged()` does the same
/// on the viewer's own notice. An answer that outlived either lands nowhere. A refusal goes to the
/// session's one decision rule (`onUnauthorized`), as every other store's does.
@MainActor
@Observable
public final class MediaContextStore {
    public enum Lookup<Value: Equatable & Sendable>: Equatable, Sendable {
        case found(Value)
        case unavailable
    }

    /// One time the Info sheet is open, about one file.
    public struct Opening: Hashable, Sendable {
        public let uid: String
        fileprivate let serial: Int
    }

    public private(set) var memos: [String: Lookup<Memo>] = [:]
    /// The live opening's answer, and nothing older.
    private var answered: (opening: Opening, lookup: Lookup<AttachmentFacts>)?
    private var live: Opening?

    private var generation = 0
    /// The session generation what is held was read under; nil while nothing is.
    private var heldUnder: Int?
    private var memoFlights: [String: Flight] = [:]
    private var factFlight: (opening: Opening, flight: Flight)?
    /// The opening whose record has been ASKED for, whatever came back — a failure included, so
    /// one opening never asks twice. A new opening is another value and asks again.
    private var attempted: Opening?
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

    /// The memo held for `uid`, or nil when none was found (yet) for the session now current.
    public func memo(_ uid: String) -> Memo? {
        guard heldIsCurrent, case .found(let memo) = memos[uid] else { return nil }
        return memo
    }

    /// The file record `opening` read, or nil — nil too once the opening has closed.
    public func facts(for opening: Opening) -> AttachmentFacts? {
        guard heldIsCurrent, live == opening, let answered, answered.opening == opening,
            case .found(let facts) = answered.lookup
        else { return nil }
        return facts
    }

    /// The sheet opened about `uid`: a new opening, which any earlier one's answer cannot reach.
    public func open(_ uid: String) -> Opening {
        nextToken += 1
        let opening = Opening(uid: uid, serial: nextToken)
        live = opening
        answered = nil
        factFlight = nil
        return opening
    }

    /// The sheet that took `opening` has gone. A close for an opening already replaced does
    /// nothing: the live one is not its to end.
    public func close(_ opening: Opening) {
        guard live == opening else { return }
        live = nil
        answered = nil
        factFlight = nil
    }

    /// Reads the memo `uid` unless it is already held; joins a read already in the air.
    public func loadMemo(uid: String, using handle: SessionHandle, baseURL: URL) async {
        guard adopt(handle) else { return }
        if case .found = memos[uid] { return }
        if let running = memoFlights[uid], running.generation == generation {
            await running.task.value
            return
        }
        nextToken += 1
        let token = nextToken
        let issued = generation
        let task = Task { await self.runMemo(uid, issued, token, handle, baseURL) }
        memoFlights[uid] = Flight(token: token, generation: issued, task: task)
        await task.value
    }

    /// Reads the record of `opening`'s file once for that opening; joins its read in the air.
    /// Starts nothing for an opening that is not the live one.
    public func loadFacts(for opening: Opening, using handle: SessionHandle) async {
        guard live == opening, adopt(handle) else { return }
        if let running = factFlight, running.opening == opening,
            running.flight.generation == generation
        {
            await running.flight.task.value
            return
        }
        guard attempted != opening else { return }
        attempted = opening
        nextToken += 1
        let token = nextToken
        let issued = generation
        let task = Task { await self.runFacts(opening, issued, token, handle) }
        factFlight = (opening, Flight(token: token, generation: issued, task: task))
        await task.value
    }

    /// The account changed: nothing held is about the reader any more, and nothing in the air may
    /// land.
    public func sessionIdentityChanged() {
        generation += 1
        heldUnder = nil
        memos = [:]
        answered = nil
        attempted = nil
        memoFlights = [:]
        factFlight = nil
    }

    /// Whether `handle` may ask, settled BEFORE anything held is reused or joined: it must be the
    /// session's current one, and a generation other than the one held drops everything held.
    private func adopt(_ handle: SessionHandle) -> Bool {
        guard sessionStillCurrent(handle) else { return false }
        if heldUnder != handle.generation {
            if heldUnder != nil { sessionIdentityChanged() }
            heldUnder = handle.generation
        }
        return true
    }

    /// Whether what is held was read under the session current now.
    private var heldIsCurrent: Bool {
        guard let session else { return true }
        guard let held = heldUnder else { return true }
        return session.activeHandle?.generation == held
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
            if await settled(error, issuedUnder: handle), issued == generation {
                memos[uid] = .unavailable
            }
        }
    }

    private func runFacts(
        _ opening: Opening, _ issued: Int, _ token: Int, _ handle: SessionHandle
    ) async {
        defer { if factFlight?.flight.token == token { factFlight = nil } }
        do {
            let read = try await Self.facts(handle.client, uid: opening.uid)
            guard issued == generation, live == opening, sessionStillCurrent(handle) else {
                MemosLog.api.info("a file record answered for an opening that has gone; dropped")
                return
            }
            answered = (opening, .found(read))
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else { return }
            if await settled(error, issuedUnder: handle), issued == generation, live == opening {
                answered = (opening, .unavailable)
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
