import Foundation
import MemosCore
import Testing

/// The device credential's state machine: where it lives, how it gets there from the two places it
/// used to live, and what happens when two of those operations overlap.
///
/// The whole reason this type exists is that an app update must not sign anybody out, and that a
/// token must not survive a sign-out. Both are properties of ORDER, and order is what a test can
/// hold still.
@Suite("CredentialVault")
struct CredentialVaultTests {
    private let account = "device-token"
    private let credentials = KeychainNamespaces.credentials
    private let shared = KeychainNamespaces.shared
    private let appDefault = KeychainNamespaces.appDefault

    /// The three namespaces a device has, over one item table — the honest model, because the
    /// Security framework has one keychain and an item carries the group it was written under.
    private func vault(_ keychain: KeychainNamespaces, legacy: (any KeychainNamespaceStore)? = nil)
        -> CredentialVault
    {
        CredentialVault(
            CredentialNamespaces(
                primary: CredentialNamespace(keychain.grouped(credentials), reach: .appOnly),
                legacies: [
                    CredentialNamespace(keychain.grouped(shared), reach: .sharedWithExtensions),
                    CredentialNamespace(legacy ?? keychain.grouped(appDefault), reach: .appOnly),
                ]
            )
        )
    }

    private func vault(
        primary: any KeychainNamespaceStore,
        legacies: [CredentialNamespace]
    ) -> CredentialVault {
        CredentialVault(
            CredentialNamespaces(
                primary: CredentialNamespace(primary, reach: .appOnly), legacies: legacies))
    }

    // MARK: - where the credential is read from

    @Test("the credential's own namespace answers first")
    func readsPrimaryFirst() async throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(credentials).set("memos_pat_new", for: account)
        try keychain.grouped(shared).set("memos_pat_old", for: account)

        #expect(try await vault(keychain).string(for: account) == "memos_pat_new")
    }

    @Test("a token left in the app group is found AND moved out of it")
    func migratesOutOfTheAppGroup() async throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(shared).set("memos_pat_old", for: account)
        let vault = vault(keychain)

        #expect(try await vault.string(for: account) == "memos_pat_old")

        #expect(keychain.value(credentials, account) == "memos_pat_old", "it moved home")
        #expect(
            keychain.value(shared, account) == nil,
            "and it is no longer where the share extension can read it"
        )
        // The second read must not need a lap at all.
        #expect(try await vault.string(for: account) == "memos_pat_old")
    }

    @Test("a token left in the pre-entitlement namespace is found AND moved")
    func migratesOutOfTheApplicationIdentifierGroup() async throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)
        let vault = vault(keychain)

        #expect(try await vault.string(for: account) == "memos_pat_old")

        #expect(keychain.value(credentials, account) == "memos_pat_old")
        #expect(keychain.value(appDefault, account) == nil)
    }

    @Test("a namespace that refuses writes still returns the token it found")
    func keepsLegacyWhenPrimaryRefuses() async throws {
        let legacy = InMemoryCredentials()
        try legacy.set("memos_pat_old", for: account)
        let vault = vault(
            primary: RefusingCredentials(),
            legacies: [CredentialNamespace(legacy, reach: .appOnly)]
        )

        #expect(try await vault.string(for: account) == "memos_pat_old")
        #expect(
            legacy.snapshot()[account] == "memos_pat_old",
            "the only copy must survive a failed migration"
        )
    }

    @Test("nothing anywhere reads as nothing")
    func missingEverywhere() async throws {
        #expect(try await vault(KeychainNamespaces()).string(for: account) == nil)
    }

    // MARK: - what a sign-in and a sign-out leave behind

    @Test("a new token goes home and clears every older namespace")
    func setClearsEveryLegacy() async throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(shared).set("memos_pat_shared", for: account)
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        try await vault(keychain).set("memos_pat_new", for: account)

        #expect(keychain.value(credentials, account) == "memos_pat_new")
        #expect(keychain.value(shared, account) == nil)
        #expect(keychain.value(appDefault, account) == nil)
    }

    @Test("a wipe clears every namespace")
    func removeClearsEverything() async throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(credentials).set("memos_pat_new", for: account)
        try keychain.grouped(shared).set("memos_pat_shared", for: account)
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        try await vault(keychain).remove(account)

        #expect(keychain.isEmpty)
    }

    @Test("a wipe that fails in one namespace still clears the others, and says so")
    func removeReportsWhatItCouldNotClear() async throws {
        let stuck = UnwipeableCredentials()
        try stuck.set("memos_pat_old", for: account)
        let reachable = InMemoryCredentials()
        try reachable.set("memos_pat_new", for: account)
        let vault = vault(
            primary: reachable,
            legacies: [CredentialNamespace(stuck, reach: .appOnly)]
        )

        await #expect(throws: UnwipeableCredentials.Stuck.self) {
            try await vault.remove(account)
        }
        #expect(reachable.isEmpty, "the namespace that could be cleared was cleared")
    }

    // MARK: - the credential that deleted itself

    @Test("a stored token is still there afterwards")
    func setSurvivesClearingTheOtherNamespaces() async throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        try await vault(keychain).set("memos_pat_new", for: account)

        // The assertion the shipped app failed, and the reason writing a memo did nothing at all:
        // the token went into one namespace and the very next call — the one that clears the OLD
        // one — deleted it again, because it named no access group and a keychain delete that
        // names none matches every group.
        #expect(try await vault(keychain).string(for: account) == "memos_pat_new")
        #expect(keychain.value(credentials, account) == "memos_pat_new")
        #expect(keychain.value(appDefault, account) == nil, "and the old copy really did go")
    }

    @Test("clearing one namespace cannot reach into another")
    func namespacesAreDisjoint() throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(credentials).set("memos_pat_new", for: account)
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        try keychain.grouped(appDefault).remove(account)

        #expect(keychain.value(credentials, account) == "memos_pat_new")
        #expect(keychain.value(appDefault, account) == nil)
    }

    @Test("migrating a token out of an old namespace does not delete it on the way")
    func migrationSurvivesTheDelete() async throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        #expect(try await vault(keychain).string(for: account) == "memos_pat_old")
        // The read that migrates must leave the token readable, not consume it.
        #expect(try await vault(keychain).string(for: account) == "memos_pat_old")
        #expect(keychain.value(credentials, account) == "memos_pat_old")
        #expect(keychain.value(appDefault, account) == nil)
    }

    /// A migration reads an old namespace, a sign-in lands while it is holding that value, and the
    /// migration then writes what it is carrying. The value in hand is by definition the OLDER of
    /// the two, so writing it would replace a token somebody just signed in with — and a read-back
    /// would pass, because it reads what it just wrote.
    ///
    /// `add` settles it in ONE keychain call: it fills an empty namespace and refuses a full one.
    @Test("a sign-in racing a migration keeps the fresh token")
    func migrationCannotClobberAFreshSignIn() throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        let gate = GatedCredentialStore(wrapping: keychain.grouped(appDefault))
        let reader = vault(keychain, legacy: gate)
        let account = account

        let read = Box<String?>(nil)
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            read.value = (try? await reader.string(for: account)) ?? nil
            finished.signal()
        }
        // The reader now holds "memos_pat_old" and has done nothing with it yet. The sign-in goes
        // straight to the table, because a second vault would be a second lock and prove nothing.
        gate.entered.wait()
        try keychain.grouped(credentials).set("memos_pat_new", for: account)
        gate.proceed.signal()
        finished.wait()
        let seen = read.value

        #expect(
            keychain.value(credentials, account) == "memos_pat_new",
            "the migration overwrote a token that was signed in after it started reading"
        )
        #expect(seen == "memos_pat_new", "and the reader answers with the newer one")
        #expect(keychain.value(appDefault, account) == nil, "the stale copy still gets cleared")
    }

    /// The interleaving the security review named: a migration lap reads an old namespace, a
    /// SIGN-OUT clears every namespace, and the lap then writes the value it is still carrying
    /// into the namespace the sign-out has just emptied. The person is looking at a sign-in screen
    /// and the device is holding a credential.
    ///
    /// Both calls go through ONE vault, because that is what the app has — and the vault is an
    /// actor, so the second call cannot begin until the first has finished. Whichever order they
    /// arrive in, the end state is the same: the sign-out wins, because it is the operation that
    /// ran second or the one that ran on an empty keychain.
    @Test("a sign-out that lands mid-migration cannot be undone by it")
    func migrationCannotResurrectAfterSignOut() throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        let gate = GatedCredentialStore(wrapping: keychain.grouped(appDefault))
        let vault = vault(keychain, legacy: gate)
        let account = account

        let read = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await vault.string(for: account)
            read.signal()
        }
        // The lap is holding "memos_pat_old" and has written nothing yet.
        gate.entered.wait()

        let wipeStarted = DispatchSemaphore(value: 0)
        let wiped = DispatchSemaphore(value: 0)
        Task.detached {
            // Signalled before the call, so the sign-out is provably in flight while the lap is
            // still holding its value — the vault is what stops them overlapping, not the timing.
            wipeStarted.signal()
            try? await vault.remove(account)
            wiped.signal()
        }
        wipeStarted.wait()
        gate.proceed.signal()
        read.wait()
        wiped.wait()

        #expect(
            keychain.value(credentials, account) == nil,
            "the migration resurrected a credential the sign-out had removed"
        )
        #expect(keychain.value(shared, account) == nil)
        #expect(keychain.value(appDefault, account) == nil)
    }

    /// The trade the safe ordering makes. Writing first and clearing second means a crash in
    /// between leaves BOTH copies — harmless, because the credential's own namespace is what every
    /// read answers with — instead of leaving NEITHER, which would put a signed-in device through
    /// an unasked-for sign-in.
    @Test("a crash between the write and the tidy-up leaves the token, and a later read tidies")
    func crashBetweenWriteAndTidyUp() async throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        // `set` up to the write, and then the process dies.
        try keychain.grouped(credentials).set("memos_pat_new", for: account)
        #expect(keychain.value(appDefault, account) == "memos_pat_old", "both copies survive")

        // The next launch restores, gets the new token, and clears what the crash left behind.
        #expect(try await vault(keychain).string(for: account) == "memos_pat_new")
        #expect(keychain.value(appDefault, account) == nil, "the leftover is cleaned up on read")
    }

    @Test("a write that cannot be read back is not a write")
    func writeIsNotDoneUntilItReadsBack() async {
        let vault = vault(
            primary: ForgetfulCredentials(),
            legacies: [CredentialNamespace(ForgetfulCredentials(), reach: .sharedWithExtensions)]
        )

        // Both namespaces answer success and hold nothing. Nothing threw, so only looking finds
        // it — and a sign-in that believed the status code would tell someone their credential was
        // saved while the keychain held nothing.
        await #expect(throws: CredentialStoreError.notReadableBack(account: account)) {
            try await vault.set("memos_pat_new", for: account)
        }
    }

    /// The fallback exists because a credential only this app can read is worth strictly more than
    /// none. It is not a licence to put the token anywhere: the app group is where the share
    /// extension could read it, so the fallback steps over it and takes the app-only namespace.
    @Test("a fallback goes to an app-only namespace, never to the app group")
    func fallsBackToAnAppOnlyNamespace() async throws {
        let appGroup = InMemoryCredentials()
        let appOnly = InMemoryCredentials()
        let vault = vault(
            primary: ForgetfulCredentials(),
            legacies: [
                CredentialNamespace(appGroup, reach: .sharedWithExtensions),
                CredentialNamespace(appOnly, reach: .appOnly),
            ]
        )

        try await vault.set("memos_pat_new", for: account)

        #expect(appOnly.snapshot()[account] == "memos_pat_new")
        #expect(appGroup.isEmpty, "the token must never be written where an extension can read it")
        #expect(try await vault.string(for: account) == "memos_pat_new")
    }

    /// A writer that could not prove its own write knows NOTHING about what the namespace holds.
    /// Reading that as "whatever is in there is mine and may be deleted" is how a live credential
    /// vanished from a signed-in device, so there is no delete on a failed write anywhere.
    @Test("a write that fails deletes nothing, and refuses to be shadowed")
    func failedWriteDeletesNothing() async throws {
        let home = ReadOnlyCredentials(holding: [account: "memos_pat_signed_in"])
        let appGroup = InMemoryCredentials()
        let appOnly = InMemoryCredentials()
        let vault = vault(
            primary: home,
            legacies: [
                CredentialNamespace(appGroup, reach: .sharedWithExtensions),
                CredentialNamespace(appOnly, reach: .appOnly),
            ]
        )

        await #expect(throws: ReadOnlyCredentials.Refused.self) {
            try await vault.set("memos_pat_new", for: account)
        }

        #expect(
            home.snapshot()[account] == "memos_pat_signed_in",
            "the credential that was already stored was deleted by a write that failed"
        )
        // And nothing was written anywhere else: a fallback under a value that reads first would
        // have the app running on one token and storing another.
        #expect(appOnly.isEmpty)
        #expect(appGroup.isEmpty)
    }

    // MARK: - corruption is not absence

    @Test("a credential that will not read is raised, not reported as nobody being signed in")
    func unreadableHomeNamespaceSurfaces() async throws {
        let home = UnreadableCredentials()
        let legacy = InMemoryCredentials()
        try legacy.set("memos_pat_old", for: account)
        let vault = vault(
            primary: home,
            legacies: [CredentialNamespace(legacy, reach: .appOnly)]
        )

        await #expect(throws: UnreadableCredentials.Unreadable.self) {
            _ = try await vault.string(for: account)
        }
        #expect(home.removalCount == 0, "a read that failed must not delete anything")
        #expect(legacy.snapshot()[account] == "memos_pat_old")
    }

    @Test("a namespace being emptied that will not read is stepped over, not raised")
    func unreadableLegacyNamespaceIsSteppedOver() async throws {
        let home = InMemoryCredentials()
        let older = InMemoryCredentials()
        try older.set("memos_pat_old", for: account)
        let vault = vault(
            primary: home,
            legacies: [
                CredentialNamespace(UnreadableCredentials(), reach: .sharedWithExtensions),
                CredentialNamespace(older, reach: .appOnly),
            ]
        )

        #expect(try await vault.string(for: account) == "memos_pat_old")
        #expect(home.snapshot()[account] == "memos_pat_old")
    }

    // MARK: - a vault that cannot name its namespaces

    /// A namespace nobody can name does NOTHING — the vault never falls back to a query with no
    /// access group, which is the call that started all of this.
    @Test("a vault that cannot name its namespaces reads, writes and deletes nothing")
    func unnameableNamespacesAreInert() async {
        let vault = CredentialVault(resolving: { nil })

        await #expect(throws: CredentialStoreError.namespaceUnavailable) {
            _ = try await vault.string(for: account)
        }
        await #expect(throws: CredentialStoreError.namespaceUnavailable) {
            try await vault.set("memos_pat_new", for: account)
        }
        await #expect(throws: CredentialStoreError.namespaceUnavailable) {
            try await vault.remove(account)
        }
    }

    /// The probe behind the namespaces can fail for reasons that pass — a device woken before its
    /// first unlock cannot reach `AfterFirstUnlock` items at all. Remembering that failure would
    /// leave the app unable to see its own credential until somebody force-quit it.
    @Test("a vault that could not name its namespaces once tries again")
    func resolvesAgainAfterAFailedProbe() async throws {
        let attempts = Counter()
        let table = KeychainNamespaces()
        let group = credentials
        try table.grouped(group).set("memos_pat_new", for: account)
        let vault = CredentialVault(resolving: {
            attempts.increment()
            guard attempts.count > 1 else { return nil }
            return CredentialNamespaces(
                primary: CredentialNamespace(table.grouped(group), reach: .appOnly),
                legacies: []
            )
        })

        await #expect(throws: CredentialStoreError.namespaceUnavailable) {
            _ = try await vault.string(for: account)
        }
        #expect(try await vault.string(for: account) == "memos_pat_new")
        #expect(try await vault.string(for: account) == "memos_pat_new")
        #expect(attempts.count == 2, "a resolved namespace is not probed for again")
    }

    // MARK: - one vault

    /// Serialization is a property of the OBJECT. Two vaults over the same keychain would lock
    /// nothing against each other, and the session's wipe and the outbox's read would be back to
    /// racing — so the app has one, and this is the assertion that keeps it that way.
    @Test("the app composes one vault, not one per caller")
    func theProcessHasOneVault() {
        #expect(DeviceCredentials.keychain() as AnyObject === DeviceCredentials.shared as AnyObject)
        #expect(
            DeviceCredentials.keychain() as AnyObject === DeviceCredentials.keychain() as AnyObject)
    }
}
