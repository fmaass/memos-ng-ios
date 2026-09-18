import Foundation
import MemosAPI

/// Every located photo the household can see, in one answer.
///
/// `GET /api/map/markers` takes no parameters: no cursor, no bounding box, no filter. So this store
/// asks ONE question and holds its one answer, and that is why it carries no lineage counter where
/// its template (`MediaLibraryStore`) carries generation, filter and order. A counter exists there
/// because a tab change or a reversal can supersede a page in flight; nothing here can supersede
/// anything, and a counter that never advances is dead mechanism pretending to be a fence.
///
/// What a lineage would have fenced against — one session's answer landing on the next
/// one's map — is fenced twice over instead: by LIFETIME, because the signed-in view creates
/// this store and drops it with itself, so a successor session gets its own instance; and by
/// the epoch check every apply point below makes against the handle that ISSUED the request.
@MainActor
@Observable
public final class PlacesStore {
    public private(set) var markers: [PlaceMarker] = []
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    /// Whether a load has SETTLED — answered or failed, either one. It is what tells "no photo
    /// here knows where it was taken" from "nobody has asked yet", and nothing else here can:
    /// `markers` is empty before the first read and after an account with no located files, and
    /// `isLoading` is false both before a load starts and after one was cancelled.
    public private(set) var hasSettledOnce = false
    /// Whether the load that settled last failed. A fact of its own rather than
    /// `lastError != nil`, because the failure this map most has to draw — a server that never
    /// answered — deliberately leaves no sentence here at all: that one belongs to the session's
    /// banner. Derived from the sentence, it would read as "there is genuinely nothing to show".
    public private(set) var lastLoadFailed = false

    public var status: PlacesStatus {
        PlacesStatus.of(
            isPending: !hasSettledOnce,
            isError: lastLoadFailed,
            markerCount: markers.count
        )
    }

    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    /// Where a failure that never reached the server goes instead of `lastError`, and the seam this
    /// store reads the session's incarnation from — its template's, for its template's reason
    /// (`MediaLibraryStore`).
    private var session: (any SessionReporting)?

    public init(
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.onUnauthorized = onUnauthorized
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    public func load(using handle: SessionHandle, baseURL: URL) async {
        // The client and the incarnation it belongs to arrive as ONE value and are carried through
        // the request and every apply point below. Nothing here re-samples the session: re-sampling
        // is what let a request rejected as one session's reissue itself under the next one's
        // number, with the first one's client still in hand.
        let client = handle.client
        // The guard is this store's own state, never a disabled button: a second ask while the
        // first is out is REFUSED rather than joined, because there is one question and the answer
        // already on its way is the whole of it.
        guard !isLoading else { return }
        isLoading = true
        // Every exit releases it — answered, failed, cancelled, or fenced out by a session that
        // ended while the answer was in the air. There is no second reader to hand it to.
        defer { isLoading = false }
        do {
            let loaded = try await Self.markers(client, baseURL: baseURL)
            guard sessionStillCurrent(handle) else {
                MemosLog.api.info("markers answered for a session that has ended are not applied")
                return
            }
            markers = loaded
            hasSettledOnce = true
            lastLoadFailed = false
            lastError = nil
        } catch {
            await report(error, issuedUnder: handle)
        }
    }

    /// Says what went wrong, and records that the question settled — unless what went wrong was
    /// this app cancelling its own request, or an answer arriving for a session that has ended.
    /// Neither of those settled anything.
    private func report(_ error: any Error, issuedUnder handle: SessionHandle) async {
        // Fenced for the reason `MediaLibraryStore.report` is: a stale refusal reaching
        // `onUnauthorized` ends the session running now, and a stale sentence lands on a map that
        // never asked.
        guard sessionStillCurrent(handle) else {
            MemosLog.api.info("a failure for a session that has ended is not reported")
            return
        }
        // This app's own supersede coming back at it is not a failure (`StoreFailure`), so it
        // leaves the map exactly as it found it — including a first load still being pending.
        guard !StoreFailure.isCancellation(error) else {
            MemosLog.api.info("a cancelled request is not a failure and is not reported")
            return
        }
        // Written once, here, rather than beside each sentence below: the failure this map most has
        // to draw is the one that leaves no sentence at all, and a flag read off `lastError` would
        // report that one as "there is genuinely nothing to show".
        hasSettledOnce = true
        lastLoadFailed = true
        // A server that never answered goes to the session and nowhere else — the same rule, and
        // the same reason, as `MediaLibraryStore.report`.
        if let failure = StoreFailure.transportFailure(error) {
            // And a sentence an earlier failure left must not stand in for this one: the banner
            // owns what an unreachable server says, and a stale "the server returned 500" under it
            // would be the map explaining this failure with the last one's words.
            lastError = nil
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            return
        }
        // The SESSION owns the verdict; this store owns only what it says about it — the same
        // rule, and the same reason, as `MediaLibraryStore.report`. The refusal is forwarded as
        // the typed value it arrived as, the epoch it presented included; nothing here re-derives
        // it, filters it or turns it into a Bool.
        if let refusal = StoreFailure.refusal(error) {
            if await onUnauthorized(refusal) == .endedSession {
                lastError = refusal.errorDescription
            }
            return
        }
        guard let apiError = StoreFailure.reportable(error) else { return }
        lastError = apiError.errorDescription
    }

    /// Whether the session that ISSUED an operation is still the one this device is running — the
    /// same guard, for the same reason, as `MediaLibraryStore.sessionStillCurrent`.
    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }

    /// Every located file, as the map's own model.
    ///
    /// Static and parameterless past the client, because that is what the endpoint is: the whole
    /// set, oldest first, with nothing to ask it for.
    static func markers(_ client: any APIProtocol, baseURL: URL) async throws -> [PlaceMarker] {
        switch try await client.listMarkersApiMapMarkersGet(.init()) {
        case .ok(let ok):
            let rows = try ok.body.json.markers
            MemosLog.api.info(
                "GET /api/map/markers -> 200, \(rows.count, privacy: .public) markers"
            )
            return rows.map { PlaceMarker(from: $0, baseURL: baseURL) }
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }
}
