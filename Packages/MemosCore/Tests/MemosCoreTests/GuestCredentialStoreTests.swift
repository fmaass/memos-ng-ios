import Foundation
@testable import MemosCore
import MemosOutbox
import Testing

/// The guest's credential lives beside the member's in one vault and shares nothing else with it:
/// not an account, not an epoch, not the refusal that ends it (MEMNG-1011).
///
/// The member half is real — a `SessionStore` signed in through the generated client over
/// `StubTransport`, writing its own accounts into the same vault — so "never touches the member" is
/// read back from the member's own Keychain items and epoch, not inferred.
@MainActor
@Suite("Guest credential: its own accounts and epoch, ended only by its own refusal")
struct GuestCredentialStoreTests {
    private static let passA = GuestCredential(
        deviceToken: "guest-token-a", deviceID: "device-a", tripLabel: "Lisbon",
        passExpiresAt: Date(timeIntervalSince1970: 1_800_000_000.25))
    private static let passB = GuestCredential(
        deviceToken: "guest-token-b", deviceID: "device-b", tripLabel: "Porto",
        passExpiresAt: Date(timeIntervalSince1970: 1_800_086_400))

    private func signedInMember(over vault: GuestVault) async -> SessionStore {
        let session = SessionStore(
            credentials: vault,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            sleeper: { _ in throw CancellationError() }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    /// Everything in the vault that is not a guest account, byte for byte.
    private func memberItems(_ vault: GuestVault) -> [String: String] {
        vault.inner.snapshot().filter { !GuestCredentialStore.accounts.contains($0.key) }
    }

    private func guestItems(_ vault: GuestVault) -> [String: String] {
        vault.inner.snapshot().filter { GuestCredentialStore.accounts.contains($0.key) }
    }

    private func refusal(_ status: Int, under epoch: Int?, kind: CredentialKind = .guest)
        -> OutboxRefusal
    {
        OutboxRefusal(statusCode: status, issuedUnder: epoch, what: "upload", kind: kind)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<5000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("the condition never became true")
    }

    // Mutation that turns it red: `tokenAccount = "device-token"` (the member's account name).
    @Test("store, refusal and clear leave the member's items and epoch exactly as they were")
    func theMemberIsNeverTouched() async throws {
        let vault = GuestVault()
        let session = await signedInMember(over: vault)
        let member = memberItems(vault)
        #expect(member[SessionStore.tokenAccount] != nil, "positive control: member signed in")
        #expect(member[SessionStore.serverAccount] != nil, "positive control: member signed in")
        let memberEpoch = session.epoch.current
        let memberState = session.state
        let guest = GuestCredentialStore(credentials: vault)

        try await guest.store(Self.passA)
        #expect(guestItems(vault)[GuestCredentialStore.tokenAccount] == "guest-token-a")
        #expect(memberItems(vault) == member)
        #expect(session.epoch.current == memberEpoch)

        let grant = try #require(guest.grant())
        #expect(await guest.handle(refusal(410, under: grant.epoch)) == .endedGuestMode)
        #expect(guest.current == nil)
        #expect(memberItems(vault) == member)
        #expect(session.epoch.current == memberEpoch)
        #expect(session.state == memberState)

        try await guest.store(Self.passB)
        try await guest.clear()
        #expect(guestItems(vault).isEmpty)
        #expect(memberItems(vault) == member)
        #expect(session.epoch.current == memberEpoch)
        #expect(session.state == memberState)
    }

    // Mutation that turns it red: `guard refusal.kind == .guest, ...` dropped from both rules.
    @Test("a member refusal or a guest refusal about the request leaves the guest in place")
    func onlyAGuestCredentialRefusalEndsIt() async throws {
        let vault = GuestVault()
        let guest = GuestCredentialStore(credentials: vault)
        try await guest.store(Self.passA)
        let grant = try #require(guest.grant())

        #expect(
            await guest.handle(refusal(401, under: grant.epoch, kind: .member))
                == .notAboutTheGuestCredential)
        #expect(
            await guest.handle(refusal(410, under: grant.epoch, kind: .member))
                == .notAboutTheGuestCredential)
        #expect(await guest.handle(refusal(413, under: grant.epoch)) == .notAboutTheGuestCredential)
        #expect(guest.current == Self.passA)
        #expect(guest.epoch.current == grant.epoch)
        #expect(guestItems(vault)[GuestCredentialStore.tokenAccount] == "guest-token-a")
    }

    // Mutation that turns it red: `return epoch.isCurrent(issuedUnder)` -> `return true`.
    @Test("a refusal earned under an earlier guest epoch changes nothing")
    func aStaleGuestRefusalIsANoOp() async throws {
        let vault = GuestVault()
        let guest = GuestCredentialStore(credentials: vault)
        try await guest.store(Self.passA)
        let old = try #require(guest.grant())
        try await guest.store(Self.passB)
        let epochBefore = guest.epoch.current

        #expect(await guest.handle(refusal(410, under: old.epoch)) == .superseded)
        #expect(await guest.handle(refusal(401, under: old.epoch)) == .superseded)
        #expect(guest.current == Self.passB)
        #expect(guest.epoch.current == epochBefore)
        #expect(guestItems(vault)[GuestCredentialStore.tokenAccount] == "guest-token-b")

        // An unknown epoch reads as current, the convention every refusal lane shares.
        #expect(await guest.handle(refusal(401, under: nil)) == .endedGuestMode)
        #expect(guest.current == nil)
    }

    // Mutation that turns it red: `removeAll(Self.accounts)` -> a loop of `remove(_:)`.
    @Test("a store is one setAll and a current refusal clears every guest item in one removeAll")
    func oneWriteInOneRemovalOut() async throws {
        let vault = GuestVault()
        let guest = GuestCredentialStore(credentials: vault)
        try await guest.store(Self.passA)
        #expect(vault.setAllCalls.map { Set($0.keys) } == [Set(GuestCredentialStore.accounts)])
        let grant = try #require(guest.grant())

        #expect(await guest.handle(refusal(401, under: grant.epoch)) == .endedGuestMode)
        #expect(vault.removeAllCalls == [GuestCredentialStore.accounts])
        #expect(vault.singleRemoves == 0)
        #expect(guestItems(vault).isEmpty)
        #expect(guest.current == nil)
        #expect(guest.grant() == nil)
        #expect(guest.epoch.current != grant.epoch)
    }

    // Mutations that turn it red: `await previous?.value` deleted (the clear's removal lands first
    // and the store's write after it), or `guard self.owns(ticket)` deleted (A is published).
    @Test("a store overlapped by a clear ends cleared: the last call made decides")
    func aStoreThatOutlivedAClearDoesNotResurrect() async throws {
        let vault = GuestVault()
        let guest = GuestCredentialStore(credentials: vault)
        vault.holdWrites()
        let storing = Task { try await guest.store(Self.passA) }
        try await waitUntil { vault.writesWaiting == 1 }
        let storeIssued = guest.epoch.current
        let clearing = Task { try await guest.clear() }
        try await waitUntil { guest.epoch.current > storeIssued }
        vault.releaseWrites()
        try await storing.value
        try await clearing.value

        #expect(guest.current == nil)
        #expect(guest.grant() == nil)
        #expect(guestItems(vault).isEmpty)
        #expect(vault.setAllCalls.count == 1, "positive control: the store's write did land")
    }

    @Test("a clear overlapped by a store ends stored, and two stores end with the second")
    func theLastCallDecides() async throws {
        let vault = GuestVault()
        let guest = GuestCredentialStore(credentials: vault)
        try await guest.store(Self.passA)

        let before = guest.epoch.current
        let clearing = Task { try await guest.clear() }
        try await waitUntil { guest.epoch.current > before }
        let storing = Task { try await guest.store(Self.passB) }
        try await clearing.value
        try await storing.value
        #expect(guest.current == Self.passB)
        #expect(guestItems(vault)[GuestCredentialStore.tokenAccount] == "guest-token-b")

        vault.holdWrites()
        let first = Task { try await guest.store(Self.passA) }
        try await waitUntil { vault.writesWaiting == 1 }
        let firstIssued = guest.epoch.current
        let second = Task { try await guest.store(Self.passB) }
        try await waitUntil { guest.epoch.current > firstIssued }
        vault.releaseWrites()
        try await first.value
        try await second.value
        #expect(guest.current == Self.passB)
        #expect(guestItems(vault)[GuestCredentialStore.tokenAccount] == "guest-token-b")
    }

    // Mutation that turns it red: `String(credential.passExpiresAt.timeIntervalSince1970)` written
    // as whole seconds (the fractional expiry no longer round-trips).
    @Test("a stored pass restores whole, and a half-stored one restores as no pass")
    func restoreReadsBackOnlyAWholePass() async throws {
        let vault = GuestVault()
        try await GuestCredentialStore(credentials: vault).store(Self.passA)

        let relaunched = GuestCredentialStore(credentials: vault)
        try await relaunched.restore()
        #expect(relaunched.current == Self.passA)
        #expect(relaunched.grant()?.token == "guest-token-a")

        try vault.inner.remove(GuestCredentialStore.deviceAccount)
        let halfStored = GuestCredentialStore(credentials: vault)
        try await halfStored.restore()
        #expect(halfStored.current == nil)
        #expect(halfStored.grant() == nil)
    }

    // Mutation that turns it red: `clearFailed = true` deleted from `removeItems`.
    @Test("a removal that fails still ends guest mode, and says it failed")
    func aFailedRemovalIsNotSwallowed() async throws {
        let vault = GuestVault()
        let guest = GuestCredentialStore(credentials: vault)
        try await guest.store(Self.passA)
        let grant = try #require(guest.grant())
        vault.failRemovals()

        #expect(await guest.handle(refusal(410, under: grant.epoch)) == .endedGuestMode)
        #expect(guest.current == nil)
        #expect(guest.grant() == nil)
        #expect(guest.clearFailed)
        await #expect(throws: GuestVault.Refused.self) { try await guest.clear() }
    }

    // Mutations that turn it red: `stillCurrent` answering `true`, or the `kind == .guest` check
    // dropped from `isCurrent`.
    @Test("the guest outbox credentials are guest, at the door, and fenced on the guest epoch")
    func guestOutboxCredentialsFenceOnTheGuestEpoch() async throws {
        let vault = GuestVault()
        let guest = GuestCredentialStore(credentials: vault)
        try await guest.store(Self.passA)
        let provider = GuestOutboxCredentials(store: guest)

        let granted = try #require(await provider.currentCredentials())
        #expect(granted.kind == .guest)
        #expect(granted.serverBaseURL == GuestDoor.baseURL)
        #expect(granted.token == "guest-token-a")
        #expect(granted.ownerSubject == "device-a")
        #expect(provider.isCurrent(granted))
        #expect(provider.stillCurrent(epoch: granted.epoch))

        // The member signing in moves the member's epoch, not this one.
        let session = await signedInMember(over: vault)
        #expect(session.state != .signedOut, "positive control: the member is signed in")
        #expect(provider.stillCurrent(epoch: granted.epoch))

        var asMember = granted
        asMember.kind = .member
        #expect(!provider.isCurrent(asMember))

        try await guest.clear()
        #expect(!provider.isCurrent(granted))
        #expect(!provider.stillCurrent(epoch: granted.epoch))
        #expect(await provider.currentCredentials() == nil)
    }
}

/// A vault over `InMemoryCredentials` that writes down every batch call, can hold a `setAll` at
/// its door until released, and can refuse removals — so overlap and failure are scripted, not
/// raced.
private final class GuestVault: CredentialStore, @unchecked Sendable {
    struct Refused: Error {}

    let inner = InMemoryCredentials()
    private let lock = NSLock()
    private var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var setAlls: [[String: String]] = []
    private var removeAlls: [[String]] = []
    private var removes = 0
    private var refusing = false

    func holdWrites() { lock.withLock { holding = true } }

    func releaseWrites() {
        let held: [CheckedContinuation<Void, Never>] = lock.withLock {
            holding = false
            defer { waiting = [] }
            return waiting
        }
        for continuation in held { continuation.resume() }
    }

    func failRemovals() { lock.withLock { refusing = true } }

    var writesWaiting: Int { lock.withLock { waiting.count } }
    /// Only the batches that wrote a guest account: the member's sign-in writes through here too.
    var setAllCalls: [[String: String]] {
        lock.withLock {
            setAlls.filter { !Set($0.keys).isDisjoint(with: GuestCredentialStore.accounts) }
        }
    }
    var removeAllCalls: [[String]] { lock.withLock { removeAlls } }
    var singleRemoves: Int { lock.withLock { removes } }

    func set(_ value: String, for account: String) throws { try inner.set(value, for: account) }

    func setAll(_ values: [String: String]) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let held: Bool = lock.withLock {
                guard holding else { return false }
                waiting.append(continuation)
                return true
            }
            if !held { continuation.resume() }
        }
        lock.withLock { setAlls.append(values) }
        for (account, value) in values { try inner.set(value, for: account) }
    }

    func string(for account: String) throws -> String? { try inner.string(for: account) }

    func remove(_ account: String) throws {
        lock.withLock { removes += 1 }
        try inner.remove(account)
    }

    func removeAll(_ accounts: [String]) async throws {
        let refused: Bool = lock.withLock {
            removeAlls.append(accounts)
            return refusing
        }
        if refused { throw Refused() }
        for account in accounts { try inner.remove(account) }
    }
}
