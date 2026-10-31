import Foundation
import MemosOutbox
import Observation

/// What a redeemed trip pass leaves on the device: the guest's own token and device, and what the
/// app needs to say which trip it is sending to and until when.
///
/// The door's address is deliberately NOT part of it. It is `GuestDoor.baseURL`, fixed in code: an
/// address read back from storage would be one more way for a guest token to reach a host that is
/// not the door.
public struct GuestCredential: Sendable, Equatable {
    public let deviceToken: String
    public let deviceID: String
    public let tripLabel: String
    public let passExpiresAt: Date

    public init(deviceToken: String, deviceID: String, tripLabel: String, passExpiresAt: Date) {
        self.deviceToken = deviceToken
        self.deviceID = deviceID
        self.tripLabel = tripLabel
        self.passExpiresAt = passExpiresAt
    }

    /// The pass as the door answered the redeem with it.
    public init(redeemed: GuestWire.Redeemed) {
        self.init(
            deviceToken: redeemed.deviceToken,
            deviceID: redeemed.deviceID,
            tripLabel: redeemed.pass.label,
            passExpiresAt: redeemed.pass.expiresAt
        )
    }
}

extension GuestCredential: CustomStringConvertible, CustomDebugStringConvertible {
    // A credential interpolated into a log line must not carry its token with it.
    public var description: String { "GuestCredential(device: \(deviceID), trip: \(tripLabel))" }
    public var debugDescription: String { description }
}

/// What a guest refusal did — returned, so a caller that reports it does not re-derive the rule.
public enum GuestRefusalOutcome: Sendable, Equatable {
    /// The refusal named the guest credential this device is holding; guest mode is over.
    case endedGuestMode
    /// It named a guest credential this device has already replaced or let go of. Nothing changed.
    case superseded
    /// A member refusal, or a guest one about the request rather than the credential. Nothing
    /// changed: this store only ever ends guest mode, and only for its own credential.
    case notAboutTheGuestCredential
}

/// The guest's credential, kept apart from the member's in everything but the vault it is stored
/// in.
///
/// Its own Keychain accounts, its own epoch, its own decision rule. The member's `SessionStore`
/// never reads an account written here and nothing here reads or removes one of the member's, so a
/// guest pass ending can never sign the household member out, and a member signing out does not
/// end a pass this device is holding for a trip.
///
/// Every mutation (store, clear, restore) runs strictly in the order it was CALLED, through one
/// chain, and the state a mutation publishes is the state of the LAST call made: a store overlapped
/// by a clear ends cleared, a clear overlapped by a store ends stored, two stores end with the
/// second. A store or restore whose answer arrives after a later call was made publishes nothing,
/// so a write that outlived a clear cannot bring the guest back in memory, and the chain means its
/// Keychain write lands BEFORE the clear's removal, never after it.
@MainActor
@Observable
public final class GuestCredentialStore {
    public nonisolated static let tokenAccount = "guest-device-token"
    public nonisolated static let deviceAccount = "guest-device-id"
    public nonisolated static let labelAccount = "guest-pass-label"
    public nonisolated static let expiryAccount = "guest-pass-expires"

    /// Every account a guest owns, in the one list a clear removes in one call.
    public nonisolated static let accounts = [
        tokenAccount, deviceAccount, labelAccount, expiryAccount,
    ]

    /// The guest this device is sending as, or nil outside guest mode.
    public private(set) var current: GuestCredential?

    /// Whether the last clear could not empty the Keychain. Guest mode ended in memory regardless
    /// (the epoch moved and nothing grants the token any more), but a relaunch's `restore` would
    /// read the pass back, which the door then refuses again.
    public private(set) var clearFailed = false

    /// The guest authority epoch, a number of its OWN: the member's `SessionStore.epoch` never
    /// moves with it and it never moves with that one. Read synchronously by the outbox's fences
    /// (`GuestOutboxCredentials`). Moved in the same synchronous step as `current`.
    public nonisolated let epoch = SessionEpoch()

    @ObservationIgnored private let credentials: any CredentialStore
    /// The last mutation in the chain; the next one waits for it.
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// Which call was made last. A mutation publishes only while it is still the last one.
    @ObservationIgnored private var latestTicket = 0

    public init(credentials: any CredentialStore) {
        self.credentials = credentials
    }

    /// Stores a redeemed pass and, once the Keychain holds all of it, makes it the guest.
    ///
    /// The guest it replaces is withdrawn at the CALL, before the write: its grants stop being
    /// current at once, so a refusal of the old pass that arrives while the new one is being
    /// written is a stale one and cannot end the pass replacing it.
    public func store(_ credential: GuestCredential) async throws {
        let ticket = withdraw()
        let items = Self.items(of: credential)
        try await inOrder {
            try await self.credentials.setAll(items)
            guard self.owns(ticket) else { return }
            self.publish(credential)
        }
    }

    /// Ends guest mode: withdrawn in memory synchronously, then every guest account removed in ONE
    /// call.
    public func clear() async throws {
        withdraw()
        try await removeItems()
    }

    /// Reads a stored pass back, at launch. Anything less than a whole pass is no pass.
    public func restore() async throws {
        latestTicket += 1
        let ticket = latestTicket
        try await inOrder {
            var values: [String: String] = [:]
            for account in Self.accounts {
                values[account] = try await self.credentials.string(for: account)
            }
            guard self.owns(ticket) else { return }
            if let restored = Self.credential(from: values) {
                self.publish(restored)
            } else if self.current != nil {
                self.current = nil
                self.epoch.bump()
            }
        }
    }

    /// The grant the guest outbox drains under, built from one state in one instant.
    public func grant() -> OutboxCredentials? {
        guard let current else { return nil }
        return OutboxCredentials(
            serverBaseURL: GuestDoor.baseURL,
            ownerSubject: current.deviceID,
            token: current.deviceToken,
            epoch: epoch.current,
            kind: .guest
        )
    }

    /// THE guest refusal rule, in one place: whether a refusal ends the guest this device holds
    /// NOW. A member refusal never does. A guest refusal does when it is about the credential (a
    /// rejected token, or a pass the door says has ended) and was earned under the current guest
    /// epoch; an unknown epoch is read as current, the convention every refusal lane shares.
    ///
    /// Asked synchronously at the effect, on the main actor, and nowhere else.
    public func concernsCurrentGuest(_ refusal: OutboxRefusal) -> Bool {
        guard refusal.kind == .guest, refusal.concernsCredential, current != nil else {
            return false
        }
        guard let issuedUnder = refusal.issuedUnder else { return true }
        return epoch.isCurrent(issuedUnder)
    }

    /// The one entry point the app calls with a guest refusal. Ends guest mode only — never a
    /// member account, never the member's session — and only when the refusal is about the guest
    /// credential held now. The rule is answered and the withdrawal written in one synchronous
    /// step, before the first await.
    @discardableResult
    public func handle(_ refusal: OutboxRefusal) async -> GuestRefusalOutcome {
        guard refusal.kind == .guest, refusal.concernsCredential else {
            return .notAboutTheGuestCredential
        }
        guard concernsCurrentGuest(refusal) else {
            MemosLog.session.info("a refusal of a guest pass this device let go of ends nothing")
            return .superseded
        }
        withdraw()
        do {
            try await removeItems()
        } catch {
            let detail = String(describing: error)
            MemosLog.session.error("the ended guest pass could not be removed: \(detail)")
        }
        return .endedGuestMode
    }

    // MARK: - internals

    /// Takes the next ticket and withdraws the guest in the same synchronous step.
    @discardableResult
    private func withdraw() -> Int {
        latestTicket += 1
        if current != nil { current = nil }
        epoch.bump()
        return latestTicket
    }

    private func removeItems() async throws {
        do {
            try await inOrder { try await self.credentials.removeAll(Self.accounts) }
            clearFailed = false
        } catch {
            clearFailed = true
            throw error
        }
    }

    private func publish(_ credential: GuestCredential) {
        current = credential
        clearFailed = false
        epoch.bump()
    }

    private func owns(_ ticket: Int) -> Bool { ticket == latestTicket }

    /// Runs `work` after every mutation called before it has finished, success or not.
    private func inOrder(_ work: @escaping @MainActor @Sendable () async throws -> Void)
        async throws
    {
        let previous = tail
        let step = Task { @MainActor in
            await previous?.value
            try await work()
        }
        tail = Task { @MainActor in _ = await step.result }
        try await step.value
    }

    private static func items(of credential: GuestCredential) -> [String: String] {
        [
            tokenAccount: credential.deviceToken,
            deviceAccount: credential.deviceID,
            labelAccount: credential.tripLabel,
            expiryAccount: String(credential.passExpiresAt.timeIntervalSince1970),
        ]
    }

    private static func credential(from values: [String: String]) -> GuestCredential? {
        guard let token = values[tokenAccount], !token.isEmpty,
            let device = values[deviceAccount], !device.isEmpty,
            let label = values[labelAccount],
            let expiry = values[expiryAccount].flatMap(Double.init)
        else { return nil }
        return GuestCredential(
            deviceToken: token, deviceID: device, tripLabel: label,
            passExpiresAt: Date(timeIntervalSince1970: expiry)
        )
    }
}

/// What the GUEST outbox is allowed to upload as: the guest pass, at the guest door, fenced on the
/// guest epoch.
///
/// Built from the guest store itself rather than from an epoch closure, so it cannot be wired to
/// the member's epoch by mistake — the member's `DeviceOutboxCredentials` is the other half and
/// takes the session's.
public struct GuestOutboxCredentials: OutboxCredentialsProviding {
    private let store: GuestCredentialStore
    private let epoch: SessionEpoch

    public init(store: GuestCredentialStore) {
        self.store = store
        self.epoch = store.epoch
    }

    public func currentCredentials() async -> OutboxCredentials? {
        await store.grant()
    }

    /// Synchronous, on the guest epoch. A member credential is never current here, whatever its
    /// number: the two epochs count independently and may well agree.
    public func isCurrent(_ credentials: OutboxCredentials) -> Bool {
        credentials.kind == .guest && epoch.isCurrent(credentials.epoch)
    }

    public func stillCurrent(epoch: Int) -> Bool {
        self.epoch.isCurrent(epoch)
    }
}
