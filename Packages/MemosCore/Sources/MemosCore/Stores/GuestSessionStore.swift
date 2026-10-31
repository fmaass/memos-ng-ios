import Foundation
import HTTPTypes
import MemosAPI
import MemosOutbox
import Observation
import OpenAPIRuntime

/// Guest mode: a trip pass redeemed on this device, what the door says about it, and leaving it.
///
/// The member's `SessionStore` is never asked anything here and never handed anything from here.
/// The pass is kept by `GuestCredentialStore` (its own accounts, its own epoch), every guest
/// refusal is decided by that store's one rule, and the share extension learns of the pass from the
/// guest licence this store publishes and withdraws.
///
/// The door is spoken to through ONE seam, `GuestDoorClient`, over a transport the caller hands in:
/// the requests are built from the `GuestWire` mirrors and carry the server's own operation ids, so
/// the generated guest client can take this seam's place without the store noticing.
///
/// Overlapping redeems JOIN: while one is on the wire, a second call waits for it and returns its
/// outcome, so two taps (or a tap and an opened link) are one request. Every read is judged against
/// the guest epoch that issued it: an answer that outlived a leave or a newer pass publishes
/// nothing. A redeem is judged the same way against the session generation it was sent under: a
/// pass the door hands over after a leave is not taken.
@MainActor
@Observable
public final class GuestSessionStore {
    public enum State: Sendable, Equatable {
        /// No pass on this device.
        case none
        /// A redeem is on the wire.
        case redeeming
        /// Sending to this trip until the pass's end.
        case active(label: String, expiresAt: Date)
        /// The door ended the pass this device held (expired, revoked or suspended). Guest mode is
        /// over; nothing of the member's changed.
        case ended
        /// The last redeem did not give this device a pass.
        case refused(RedeemRefusal)

        public var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    /// Why a redeem gave no pass, in the terms the person is shown.
    public enum RedeemRefusal: Sendable, Equatable {
        /// Not a trip-pass link at all.
        case notAPassLink
        /// The door knows no such pass.
        case unknownPass
        /// The pass exists and is no longer open.
        case passEnded
        /// Too many attempts, or the pass has no room for another device. Try again later.
        case tooManyAttempts
        /// The door could not be reached, or answered something this app cannot read.
        case unavailable

        public var message: String {
            switch self {
            case .notAPassLink: "That is not a trip-pass link."
            case .unknownPass: "This trip pass does not exist."
            case .passEnded: "This trip pass has ended."
            case .tooManyAttempts: "Too many tries just now, or the trip is full. Try again later."
            case .unavailable: "The trip could not be reached. Try again."
            }
        }
    }

    public private(set) var state: State = .none
    /// What the door says this device has sent, newest first as the door orders them.
    public private(set) var receipts: [GuestWire.Receipt] = []

    @ObservationIgnored private let credentials: GuestCredentialStore
    @ObservationIgnored private let licence: (any OutboxAccountPublishing)?
    @ObservationIgnored private let door: GuestDoorClient
    @ObservationIgnored private let displayName: String
    @ObservationIgnored private var redeeming: Task<State, Never>?
    /// Moved, synchronously, by every mutation that ends guest mode: `leave`, and a refusal that
    /// ends the pass. A redeem reads it before its request is sent; once it has moved, whatever
    /// the redeem hears back is dropped — the guest credential epoch cannot say this, because a
    /// redeem made after the leave would bump it too.
    @ObservationIgnored private var generation = 0
    /// The guest captures already held for credentials when the queue last changed.
    @ObservationIgnored private var noticedHolds: Set<UUID> = []
    /// Called on the main actor when a pass becomes this device's (redeemed or restored), so the
    /// app can compose the guest queue for it.
    @ObservationIgnored public var onActivated: (@MainActor () -> Void)?

    public init(
        credentials: GuestCredentialStore,
        licence: (any OutboxAccountPublishing)?,
        // The door's own URLSession transport unless a test scripts one — a default here, so the
        // app composes the store without naming the API layer it never imports.
        transport: any ClientTransport = APIClientFactory.guestTransport(),
        displayName: String
    ) {
        self.credentials = credentials
        self.licence = licence
        self.door = GuestDoorClient(transport: transport)
        self.displayName = displayName
    }

    /// Redeems the pass a link carries. Joins a redeem already on the wire.
    @discardableResult
    public func redeem(passLink url: URL) async -> State {
        if let redeeming { return await redeeming.value }
        guard let secret = GuestDoor.secret(fromPassLink: url) else {
            return settle(.notAPassLink)
        }
        return await redeem(secret: secret)
    }

    /// Redeems a pass secret. Joins a redeem already on the wire: one request, one outcome.
    @discardableResult
    public func redeem(secret: String) async -> State {
        if let redeeming { return await redeeming.value }
        let task = Task { @MainActor in await self.performRedeem(secret: secret) }
        redeeming = task
        let outcome = await task.value
        redeeming = nil
        return outcome
    }

    /// At launch: reads a stored pass back, shows it at once, then asks the door whether it stands.
    public func restore() async {
        try? await credentials.restore()
        guard let current = credentials.current else { return }
        activate(current, label: current.tripLabel, expiresAt: current.passExpiresAt)
        await confirm()
    }

    /// `GET /api/guest/me`: whether the pass this device holds still stands. A refusal about the
    /// credential ends guest mode; any other failure leaves the pass as it was.
    public func confirm() async {
        guard let grant = credentials.grant() else { return }
        let answer = await door.me(token: grant.token)
        guard credentials.epoch.isCurrent(grant.epoch) else { return }
        switch answer {
        case .success(let me):
            state = .active(label: me.pass.label, expiresAt: me.pass.expiresAt)
        case .refused(let status):
            await refused(status, issuedUnder: grant.epoch, what: "trip pass")
        case .failed:
            return
        }
    }

    /// `GET /api/guest/batches`: what this device has sent to the trip.
    public func refreshReceipts() async {
        guard let grant = credentials.grant() else { return }
        let answer = await door.batches(token: grant.token)
        guard credentials.epoch.isCurrent(grant.epoch) else { return }
        switch answer {
        case .success(let batches):
            receipts = batches
        case .refused(let status):
            await refused(status, issuedUnder: grant.epoch, what: "trip receipts")
        case .failed:
            return
        }
    }

    /// Leaves the trip: the pass and its licence go, so the share sheet stops offering the trip.
    ///
    /// Captures still queued for the trip stay where they are, held: they are bound to this pass's
    /// device, so the outbox's account fence never sends them under a pass redeemed later.
    public func leave() async {
        generation += 1
        withdrawLicence()
        receipts = []
        state = .none
        do {
            try await credentials.clear()
        } catch {
            let detail = String(describing: error)
            MemosLog.session.error("the guest pass could not be removed on leave: \(detail)")
        }
    }

    /// A guest refusal from somewhere else (the guest outbox): the one rule decides it.
    @discardableResult
    public func handle(_ refusal: OutboxRefusal) async -> GuestRefusalOutcome {
        if credentials.concernsCurrentGuest(refusal) {
            generation += 1
            withdrawLicence()
            receipts = []
            state = .ended
        }
        return await credentials.handle(refusal)
    }

    /// The guest queue changed. A capture newly held for credentials under THIS pass means the
    /// door turned the pass's token away mid-send — but the queue only holds; it decides nothing
    /// about the pass, and it has no channel to say so. So the door is asked again (`confirm`),
    /// under the epoch current at the asking, and its answer reaches the one refusal rule fenced on
    /// that epoch. A hold already asked about is not asked about twice: the set of holds is claimed
    /// synchronously, before the await, so two changes in a row are one request.
    public func guestQueueChanged(_ jobs: [UploadJob]) async {
        let held = GuestHeldJobs.heldForCredentials(jobs, device: credentials.current?.deviceID)
        let fresh = held.subtracting(noticedHolds)
        // Holds that ended are forgotten, so a capture retried and held again asks again.
        noticedHolds = held
        guard !fresh.isEmpty else { return }
        await confirm()
    }

    // MARK: - internals

    private func performRedeem(secret: String) async -> State {
        let issuedUnder = generation
        state = .redeeming
        let answer = await door.redeem(
            GuestWire.Redeem(secret: secret, displayName: displayName)
        )
        // A leave (or the door ending the pass) while the request was on the wire wins, whatever
        // the answer: nothing is stored, nothing is published, and the state stays the one that
        // decision set. Read with nothing awaited before the effects below.
        guard generation == issuedUnder else { return state }
        let credential: GuestCredential
        switch answer {
        case .success(let redeemed):
            credential = GuestCredential(redeemed: redeemed)
        case .refused(let status):
            return settle(Self.redeemRefusal(status))
        case .failed:
            return settle(.unavailable)
        }
        do {
            try await credentials.store(credential)
        } catch {
            guard generation == issuedUnder else { return state }
            return settle(.unavailable)
        }
        // Guest mode ended while the write was in flight. The credential store already drops a
        // write that a clear overtook; if this one landed regardless, exactly this pass is taken
        // back out.
        guard generation == issuedUnder else {
            if credentials.current == credential { await discard() }
            return state
        }
        // A leave or another pass made while the write was in flight wins: the store published
        // nothing for this one, and neither does the session.
        guard credentials.current == credential else { return state }
        activate(credential, label: credential.tripLabel, expiresAt: credential.passExpiresAt)
        return state
    }

    /// How a redeem that gave no pass ends. A pass this device already holds stays the subject (an
    /// opened link that did not redeem does not end the trip in progress). The outcome is returned
    /// either way.
    private func settle(_ refusal: RedeemRefusal) -> State {
        if let current = credentials.current {
            state = .active(label: current.tripLabel, expiresAt: current.passExpiresAt)
        } else {
            state = .refused(refusal)
        }
        return .refused(refusal)
    }

    private func activate(_ credential: GuestCredential, label: String, expiresAt: Date) {
        licence?.publish(
            AccountBinding(
                serverBaseURL: GuestDoor.baseURL, ownerSubject: credential.deviceID, kind: .guest
            )
        )
        state = .active(label: label, expiresAt: expiresAt)
        onActivated?()
    }

    private func refused(_ status: Int, issuedUnder epoch: Int, what: String) async {
        let refusal = OutboxRefusal(
            statusCode: status, issuedUnder: epoch, what: what, kind: .guest
        )
        await handle(refusal)
    }

    /// Takes a pass back out of the guest accounts after guest mode ended under its redeem.
    private func discard() async {
        do {
            try await credentials.clear()
        } catch {
            let detail = String(describing: error)
            MemosLog.session.error("a pass redeemed after a leave could not be removed: \(detail)")
        }
    }

    private func withdrawLicence() {
        do {
            try licence?.clear()
        } catch {
            let detail = String(describing: error)
            MemosLog.session.error("the guest licence could not be withdrawn: \(detail)")
        }
    }

    static func redeemRefusal(_ status: Int) -> RedeemRefusal {
        switch status {
        case 404: .unknownPass
        case 410: .passEnded
        case 429: .tooManyAttempts
        default: .unavailable
        }
    }
}

/// Which guest captures are held because the pass this device holds NOW was turned away.
///
/// A capture of an earlier pass is not about the current one: its device is gone, and asking the
/// door about the current pass on its account would be a question nobody needs answered.
enum GuestHeldJobs {
    static func heldForCredentials(_ jobs: [UploadJob], device: String?) -> Set<UUID> {
        guard let device else { return [] }
        return Set(
            jobs.lazy
                .filter {
                    $0.state == .held && $0.holdReason == .signInRequired
                        && $0.binding.credentialKind == .guest
                        && $0.binding.ownerSubject == device
                }
                .map(\.id)
        )
    }
}

/// The guest door's three routes this store reads, as raw requests over a transport.
///
/// The one seam the generated guest client replaces: `operationID`s are the server's own.
struct GuestDoorClient: Sendable {
    enum Answer<Value: Sendable>: Sendable {
        case success(Value)
        /// A 4xx/5xx with its status, for the one rule to classify.
        case refused(Int)
        /// Unreachable, or a body this app cannot read.
        case failed
    }

    let transport: any ClientTransport

    func redeem(_ body: GuestWire.Redeem) async -> Answer<GuestWire.Redeemed> {
        guard let data = try? GuestWire.encode(body) else { return .failed }
        var request = HTTPRequest(
            method: .post, scheme: nil, authority: nil, path: "/api/pass/redeem"
        )
        request.headerFields[.contentType] = "application/json"
        return await send(request, body: data, operationID: "guestRedeem")
    }

    func me(token: String) async -> Answer<GuestWire.Me> {
        await send(
            authorized(path: "/api/guest/me", token: token), body: nil, operationID: "guestMe"
        )
    }

    func batches(token: String) async -> Answer<[GuestWire.Receipt]> {
        await send(
            authorized(path: "/api/guest/batches", token: token), body: nil,
            operationID: "guestBatches"
        )
    }

    private func authorized(path: String, token: String) -> HTTPRequest {
        var request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: path)
        request.headerFields[.authorization] = "Bearer \(token)"
        return request
    }

    private func send<Value: Decodable & Sendable>(
        _ request: HTTPRequest, body: Data?, operationID: String
    ) async -> Answer<Value> {
        var request = request
        request.headerFields[.accept] = "application/json"
        do {
            let (response, answer) = try await transport.send(
                request, body: body.map { HTTPBody($0) }, baseURL: GuestDoor.baseURL,
                operationID: operationID
            )
            guard (200..<300).contains(response.status.code) else {
                return .refused(response.status.code)
            }
            guard let answer else { return .failed }
            let data = try await Data(collecting: answer, upTo: 4 * 1024 * 1024)
            guard let value = GuestWire.decode(Value.self, from: data) else { return .failed }
            return .success(value)
        } catch {
            return .failed
        }
    }
}
