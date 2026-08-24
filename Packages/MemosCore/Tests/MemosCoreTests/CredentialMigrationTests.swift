import Foundation
import MemosCore
import Testing

/// The move of the device token into the app group's keychain namespace.
///
/// The whole reason this store exists is that an app update must not sign anybody out: a device
/// that signed in before the entitlements existed has its token in the default namespace, and the
/// only evidence that it is still found is a test that puts one there.
@Suite("MigratingCredentialStore")
struct CredentialMigrationTests {
    private let account = "device-token"

    @Test("the shared namespace answers first")
    func readsPrimaryFirst() throws {
        let primary = InMemoryCredentials()
        let legacy = InMemoryCredentials()
        try primary.set("memos_pat_new", for: account)
        try legacy.set("memos_pat_old", for: account)
        let store = MigratingCredentialStore(primary: primary, legacy: legacy)

        #expect(try store.string(for: account) == "memos_pat_new")
    }

    @Test("a token left in the old namespace is found AND moved")
    func migratesOnFirstRead() throws {
        let primary = InMemoryCredentials()
        let legacy = InMemoryCredentials()
        try legacy.set("memos_pat_old", for: account)
        let store = MigratingCredentialStore(primary: primary, legacy: legacy)

        #expect(try store.string(for: account) == "memos_pat_old")

        #expect(primary.snapshot()[account] == "memos_pat_old", "the value moved to the app group")
        #expect(legacy.isEmpty, "and the old copy is not left behind as a second credential")
        // The second read must not need the fallback at all.
        #expect(try store.string(for: account) == "memos_pat_old")
    }

    @Test("a namespace that refuses writes still returns the token it found")
    func keepsLegacyWhenPrimaryRefuses() throws {
        let legacy = InMemoryCredentials()
        try legacy.set("memos_pat_old", for: account)
        let store = MigratingCredentialStore(primary: RefusingCredentials(), legacy: legacy)

        #expect(try store.string(for: account) == "memos_pat_old")
        #expect(
            legacy.snapshot()[account] == "memos_pat_old",
            "the only copy must survive a failed migration"
        )
    }

    @Test("nothing anywhere reads as nothing")
    func missingEverywhere() throws {
        let store = MigratingCredentialStore(
            primary: InMemoryCredentials(), legacy: InMemoryCredentials()
        )
        #expect(try store.string(for: account) == nil)
    }

    @Test("a new token is written to the app group and clears the old namespace")
    func setClearsLegacy() throws {
        let primary = InMemoryCredentials()
        let legacy = InMemoryCredentials()
        try legacy.set("memos_pat_old", for: account)
        let store = MigratingCredentialStore(primary: primary, legacy: legacy)

        try store.set("memos_pat_new", for: account)

        #expect(primary.snapshot()[account] == "memos_pat_new")
        #expect(legacy.isEmpty)
    }

    @Test("a wipe clears both namespaces")
    func removeClearsBoth() throws {
        let primary = InMemoryCredentials()
        let legacy = InMemoryCredentials()
        try primary.set("memos_pat_new", for: account)
        try legacy.set("memos_pat_old", for: account)
        let store = MigratingCredentialStore(primary: primary, legacy: legacy)

        try store.remove(account)

        #expect(primary.isEmpty)
        #expect(legacy.isEmpty)
    }

    // MARK: - the credential that deleted itself

    private let shared = KeychainNamespaces.shared
    private let appDefault = KeychainNamespaces.appDefault

    private func store(_ keychain: KeychainNamespaces) -> MigratingCredentialStore {
        MigratingCredentialStore(
            primary: keychain.grouped(shared), legacy: keychain.grouped(appDefault)
        )
    }

    @Test("a stored token is still there afterwards")
    func setSurvivesClearingTheOtherNamespace() throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        try store(keychain).set("memos_pat_new", for: account)

        // The assertion the shipped app failed, and the reason writing a memo did nothing at all:
        // the token went into the shared namespace and the very next call — the one that clears
        // the OLD namespace — deleted it again, because it named no access group and a keychain
        // delete that names none matches every group. The session never noticed (its client holds
        // the token in memory); the outbox reads the keychain on every drain, so it refused every
        // capture from there on.
        #expect(try store(keychain).string(for: account) == "memos_pat_new")
        #expect(keychain.value(shared, account) == "memos_pat_new")
        #expect(keychain.value(appDefault, account) == nil, "and the old copy really did go")
    }

    @Test("clearing one namespace cannot reach into the other")
    func namespacesAreDisjoint() throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(shared).set("memos_pat_new", for: account)
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        try keychain.grouped(appDefault).remove(account)

        #expect(keychain.value(shared, account) == "memos_pat_new")
        #expect(keychain.value(appDefault, account) == nil)
    }

    @Test("migrating a token out of the old namespace does not delete it on the way")
    func migrationSurvivesTheDelete() throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        #expect(try store(keychain).string(for: account) == "memos_pat_old")
        // The read that migrates must leave the token readable, not consume it.
        #expect(try store(keychain).string(for: account) == "memos_pat_old")
        #expect(keychain.value(shared, account) == "memos_pat_old")
        #expect(keychain.value(appDefault, account) == nil)
    }

    /// The race the review named: a migration reads the old namespace, a sign-in lands while it is
    /// holding that value, and the migration then writes what it is carrying. The value in hand is
    /// by definition the OLDER of the two, so writing it would replace a token somebody just
    /// signed in with — and the read-back would pass, because it reads what it just wrote.
    ///
    /// Two things stop it now and both are asserted here: the reader's delete is scoped to the old
    /// namespace, so it cannot touch the fresh item; and the reader FILLS the shared namespace
    /// with `add` rather than overwriting it with `set`, which the keychain settles in one call.
    @Test("a sign-in racing a migration keeps the fresh token")
    func migrationCannotClobberAFreshSignIn() throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        let gate = GatedCredentialStore(wrapping: keychain.grouped(appDefault))
        let reader = MigratingCredentialStore(primary: keychain.grouped(shared), legacy: gate)
        let account = account

        let seen = Box<String?>(nil)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            seen.value = (try? reader.string(for: account)) ?? nil
            finished.signal()
        }
        thread.start()

        // The reader now holds "memos_pat_old" and has done nothing with it yet.
        gate.entered.wait()
        try store(keychain).set("memos_pat_new", for: account)
        gate.proceed.signal()
        finished.wait()

        #expect(
            keychain.value(shared, account) == "memos_pat_new",
            "the migration overwrote a token that was signed in after it started reading"
        )
        #expect(seen.value == "memos_pat_new", "and the reader answers with the newer one")
        #expect(keychain.value(appDefault, account) == nil, "the stale copy still gets cleared")
    }

    /// The trade the safe ordering makes. Writing first and clearing second means a crash in
    /// between leaves BOTH copies — harmless, because the shared one is what every read answers
    /// with — instead of leaving NEITHER, which is what the other order risked and what would put
    /// a signed-in device through an unasked-for sign-in.
    @Test("a crash between the write and the tidy-up leaves the token, and a later restore tidies")
    func crashBetweenWriteAndTidyUp() throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(appDefault).set("memos_pat_old", for: account)

        // `set` up to the write, and then the process dies.
        try keychain.grouped(shared).set("memos_pat_new", for: account)
        #expect(keychain.value(shared, account) == "memos_pat_new")
        #expect(keychain.value(appDefault, account) == "memos_pat_old", "both copies survive")

        // The next launch restores, gets the new token, and clears what the crash left behind.
        #expect(try store(keychain).string(for: account) == "memos_pat_new")
        #expect(keychain.value(appDefault, account) == nil, "the leftover is cleaned up on read")
    }

    @Test("a write that cannot be read back is not a write")
    func writeIsNotDoneUntilItReadsBack() {
        let store = MigratingCredentialStore(
            primary: ForgetfulCredentials(), legacy: ForgetfulCredentials()
        )

        // Both namespaces answer success and hold nothing. Nothing threw, so only looking finds
        // it — and a sign-in that believed the status code told someone their credential was
        // saved when the keychain was empty.
        #expect(throws: CredentialStoreError.notReadableBack(account: account)) {
            try store.set("memos_pat_new", for: account)
        }
    }

    @Test("a shared namespace that forgets falls back to the app's own")
    func fallsBackWhenTheSharedNamespaceForgets() throws {
        let legacy = InMemoryCredentials()
        let store = MigratingCredentialStore(primary: ForgetfulCredentials(), legacy: legacy)

        try store.set("memos_pat_new", for: account)

        #expect(legacy.snapshot()[account] == "memos_pat_new")
        #expect(try store.string(for: account) == "memos_pat_new")
    }

    /// A namespace nobody can name does NOTHING — it never falls back to a query with no access
    /// group, which is the call that started all of this.
    @Test("a namespace that cannot be named is inert, not ungrouped")
    func unnameableNamespaceIsInert() throws {
        let keychain = KeychainNamespaces()
        try keychain.grouped(shared).set("memos_pat_new", for: account)
        let store = MigratingCredentialStore(
            primary: keychain.grouped(shared), legacy: InertCredentialStore()
        )

        #expect(try store.string(for: account) == "memos_pat_new")
        try store.remove(account)
        #expect(keychain.value(shared, account) == nil)
    }

    @Test("the app group is named without a team id, so the repository carries no team id")
    func accessGroupIsAnAppGroup() {
        #expect(DeviceCredentials.accessGroup == "group.live.discomarder.memosng")
        #expect(DeviceCredentials.service == "live.discomarder.memosng")
    }

    /// The property the whole design rests on: the app can NAME the namespace a pre-entitlement
    /// sign-in wrote to. Without a name there is nothing to migrate from and nothing to delete —
    /// and, crucially, the app still does not reach for it with a query that names no group.
    @Test("the app's default keychain namespace can be named")
    func theDefaultNamespaceIsNameable() throws {
        let resolved = try #require(
            KeychainAccessGroup.appDefault,
            "the probe must resolve a group; an unnameable one leaves the legacy store inert"
        )
        #expect(!resolved.isEmpty)
        // And it is a real group this build can use, not just a string.
        let keychain = Keychain(service: KeychainAccessGroup.probeService, accessGroup: resolved)
        try keychain.set("memos_pat_probe", for: account)
        #expect(try keychain.string(for: account) == "memos_pat_probe")
        try keychain.remove(account)
        #expect(try keychain.string(for: account) == nil)
    }
}
