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
/// outcome, so two taps (or a tap and an opened link) are one request — sent under the FIRST
/// caller's name; a joining caller's name is neither sent nor remembered. Every read is judged
/// against the guest epoch that issued it: an answer that outlived a leave or a newer pass
/// publishes nothing. A redeem is judged the same way against the session generation it was sent
/// under: a pass the door hands over after a leave is not taken.
///
/// Overlapping renames JOIN the same way: one `PATCH /api/guest/device` on the wire, sent under the
/// first caller's name, and every caller gets its outcome. A rename answered after a leave, an
/// ended pass or a newer pass writes no name back, and a rename under a newer pass never joins one
/// the older pass left on the wire.
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

    /// What a rename after joining came to, in the terms the person is shown.
    public enum RenameRefusal: Sendable, Equatable {
        /// Nothing but blanks was typed; nothing was sent.
        case emptyName
        /// The door would not take the name.
        case invalidName
        /// The door ended the pass this device held; guest mode is over.
        case passEnded
        /// No pass on this device to rename.
        case notJoined
        /// The door could not be reached, or answered something this app cannot read.
        case unavailable

        public var message: String {
            switch self {
            case .emptyName: "Type a name first."
            case .invalidName: "The trip would not take that name. Use 1 to 64 characters."
            case .passEnded: "This trip pass has ended."
            case .notJoined: "Join a trip first."
            case .unavailable: "The name could not be saved. Try again."
            }
        }
    }

    public enum RenameOutcome: Sendable, Equatable {
        /// The door stored this name; it is shown and remembered.
        case renamed(String)
        case refused(RenameRefusal)
        /// Guest mode ended, or another pass took over, while the request was on the wire. Nothing
        /// was written.
        case superseded
    }

    public private(set) var state: State = .none
    /// What the door says this device has sent, newest first as the door orders them.
    public private(set) var receipts: [GuestWire.Receipt] = []
    /// The name the pass this device holds was redeemed under, as this device sent it. `nil` for
    /// no pass, and for a pass redeemed by a build that did not keep it.
    public private(set) var joinedName: String?

    /// Where the names are kept: the name last typed, and the name the current pass joined under.
    /// Read on every launch forever, so they are never renamed.
    public static let rememberedNameKey = "guestDisplayName"
    public static let joinedNameKey = "guestJoinedName"

    @ObservationIgnored private let credentials: GuestCredentialStore
    @ObservationIgnored private let licence: (any OutboxAccountPublishing)?
    @ObservationIgnored private let door: GuestDoorClient
    @ObservationIgnored private let names: UserDefaults
    @ObservationIgnored private var redeeming: Task<State, Never>?
    /// The rename on the wire, with the generation and credential epoch it was sent under, so only
    /// a caller under the same pass joins it.
    @ObservationIgnored private var renaming: InFlightRename?
    @ObservationIgnored private var renameCount = 0
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
        // The app group's, so the name survives the app's own container being the one that is
        // reset; a test hands in a scratch suite.
        names: UserDefaults = UserDefaults(suiteName: DeviceCredentials.appGroup) ?? .standard
    ) {
        self.credentials = credentials
        self.licence = licence
        self.door = GuestDoorClient(transport: transport)
        self.names = names
    }

    /// The name a redeem with nothing typed is sent under: the name typed last time, else
    /// `GuestName.lastResort`.
    public var presentedName: String {
        GuestName.resolve(typed: nil, remembered: names.string(forKey: Self.rememberedNameKey))
    }

    /// What the Join screen's name field starts with: the name typed last time, else empty.
    public var joinFieldName: String {
        GuestName.fieldStart(remembered: names.string(forKey: Self.rememberedNameKey))
    }

    /// Redeems the pass a link carries, under `typedName` (see `redeem(secret:typedName:)`).
    /// Joins a redeem already on the wire.
    @discardableResult
    public func redeem(passLink url: URL, typedName: String? = nil) async -> State {
        if let redeeming { return await redeeming.value }
        guard let secret = GuestDoor.secret(fromPassLink: url) else {
            return settle(.notAPassLink)
        }
        return await redeem(secret: secret, typedName: typedName)
    }

    /// Redeems a pass secret. Joins a redeem already on the wire: one request, one outcome, under
    /// the first caller's name.
    ///
    /// `typedName` is what the person typed; trimmed and capped to the door's 64, it is sent and
    /// remembered for next time. `nil` (a link opened from outside, with no field to read) sends
    /// the remembered name, else `GuestName.lastResort`. A field left or cleared blank sends
    /// `GuestName.lastResort`: the person emptied it, so a remembered name is not put back; the
    /// remembered name itself is kept for the next Join field.
    @discardableResult
    public func redeem(secret: String, typedName: String? = nil) async -> State {
        if let redeeming { return await redeeming.value }
        if let typed = GuestName.cleaned(typedName) {
            names.set(typed, forKey: Self.rememberedNameKey)
        }
        let name =
            typedName == nil ? presentedName : GuestName.resolve(typed: typedName, remembered: nil)
        let task = Task { @MainActor in await self.performRedeem(secret: secret, name: name) }
        redeeming = task
        let outcome = await task.value
        redeeming = nil
        return outcome
    }

    /// At launch: reads a stored pass back, shows it at once, then asks the door whether it stands.
    public func restore() async {
        try? await credentials.restore()
        guard let current = credentials.current else { return }
        joinedName = names.string(forKey: Self.joinedNameKey)
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

    /// `PATCH /api/guest/device`: renames the device the pass this device holds is redeemed on,
    /// under the guest token the other door calls present. Joins a rename already on the wire for
    /// the same pass: one request, one outcome, under the first caller's name.
    ///
    /// `typed` is trimmed and capped to the door's 64; blank, nothing is sent. The door's stored
    /// spelling is what is shown and remembered. A refusal goes to the one guest refusal rule,
    /// which ends guest mode when it names this pass's credential; any other refusal or failure
    /// leaves the joined name as it was.
    @discardableResult
    public func rename(to typed: String) async -> RenameOutcome {
        if let renaming, renaming.generation == generation,
            credentials.epoch.isCurrent(renaming.epoch)
        {
            return await renaming.task.value
        }
        guard let name = GuestName.cleaned(typed) else { return .refused(.emptyName) }
        guard let grant = credentials.grant() else { return .refused(.notJoined) }
        let issuedUnder = generation
        renameCount += 1
        let id = renameCount
        let task = Task { @MainActor in
            await self.performRename(name, grant: grant, issuedUnder: issuedUnder)
        }
        renaming = InFlightRename(id: id, generation: issuedUnder, epoch: grant.epoch, task: task)
        let outcome = await task.value
        if renaming?.id == id { renaming = nil }
        return outcome
    }

    /// Leaves the trip: the pass and its licence go, so the share sheet stops offering the trip.
    ///
    /// Captures still queued for the trip stay where they are, held: they are bound to this pass's
    /// device, so the outbox's account fence never sends them under a pass redeemed later.
    public func leave() async {
        generation += 1
        withdrawLicence()
        receipts = []
        forgetJoinedName()
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
            forgetJoinedName()
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

    private func performRedeem(secret: String, name: String) async -> State {
        let issuedUnder = generation
        state = .redeeming
        let answer = await door.redeem(
            GuestWire.Redeem(secret: secret, displayName: name)
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
        names.set(name, forKey: Self.joinedNameKey)
        joinedName = name
        activate(credential, label: credential.tripLabel, expiresAt: credential.passExpiresAt)
        return state
    }

    private func performRename(
        _ name: String, grant: OutboxCredentials, issuedUnder: Int
    ) async -> RenameOutcome {
        let answer = await door.renameDevice(
            GuestWire.Rename(displayName: name), token: grant.token
        )
        // A leave, an ended pass or a newer pass while the request was on the wire wins, whatever
        // the answer. Both fences, because a leave moves the generation before its credential
        // clear has moved the epoch, and a newer pass moves the epoch without a leave. Read with
        // nothing awaited before the writes below.
        guard generation == issuedUnder, credentials.epoch.isCurrent(grant.epoch) else {
            return .superseded
        }
        switch answer {
        case .success(let renamed):
            let stored = renamed.displayName
            names.set(stored, forKey: Self.joinedNameKey)
            names.set(stored, forKey: Self.rememberedNameKey)
            joinedName = stored
            return .renamed(stored)
        case .refused(let status):
            switch await refused(status, issuedUnder: grant.epoch, what: "trip name") {
            case .endedGuestMode: return .refused(.passEnded)
            case .superseded: return .superseded
            case .notAboutTheGuestCredential: return .refused(Self.renameRefusal(status))
            }
        case .failed:
            return .refused(.unavailable)
        }
    }

    private func forgetJoinedName() {
        joinedName = nil
        names.removeObject(forKey: Self.joinedNameKey)
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

    @discardableResult
    private func refused(
        _ status: Int, issuedUnder epoch: Int, what: String
    ) async -> GuestRefusalOutcome {
        let refusal = OutboxRefusal(
            statusCode: status, issuedUnder: epoch, what: what, kind: .guest
        )
        return await handle(refusal)
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

    static func renameRefusal(_ status: Int) -> RenameRefusal {
        status == 422 ? .invalidName : .unavailable
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

private struct InFlightRename {
    let id: Int
    let generation: Int
    let epoch: Int
    let task: Task<GuestSessionStore.RenameOutcome, Never>
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

/// The guest door's routes this store speaks to, as raw requests over a transport.
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

    func renameDevice(_ body: GuestWire.Rename, token: String) async -> Answer<GuestWire.Renamed> {
        guard let data = try? GuestWire.encode(body) else { return .failed }
        var request = authorized(path: "/api/guest/device", token: token, method: .patch)
        request.headerFields[.contentType] = "application/json"
        return await send(request, body: data, operationID: "guestRenameDevice")
    }

    private func authorized(
        path: String, token: String, method: HTTPRequest.Method = .get
    ) -> HTTPRequest {
        var request = HTTPRequest(method: method, scheme: nil, authority: nil, path: path)
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
