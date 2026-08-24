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

    @Test("a stored token is still there afterwards")
    func setSurvivesClearingTheOtherNamespace() throws {
        let keychain = KeychainNamespaces()
        let store = MigratingCredentialStore(
            primary: keychain.grouped(DeviceCredentials.accessGroup),
            legacy: keychain.ungrouped()
        )

        try store.set("memos_pat_new", for: account)

        // The assertion the shipped app failed, and the reason writing a memo did nothing at all:
        // the token went into the shared namespace and the very next call — the one that clears
        // the OLD namespace — deleted it again, because a keychain delete naming no access group
        // matches every group. The session never noticed (its client holds the token in memory);
        // the outbox reads the keychain on every drain, so it refused every capture from here on.
        #expect(try store.string(for: account) == "memos_pat_new")
    }

    @Test("migrating a token out of the old namespace does not delete it on the way")
    func migrationSurvivesTheUngroupedDelete() throws {
        let keychain = KeychainNamespaces()
        try keychain.ungrouped().set("memos_pat_old", for: account)
        let store = MigratingCredentialStore(
            primary: keychain.grouped(DeviceCredentials.accessGroup),
            legacy: keychain.ungrouped()
        )

        #expect(try store.string(for: account) == "memos_pat_old")
        // The read that migrates must leave the token readable, not consume it.
        #expect(try store.string(for: account) == "memos_pat_old")
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

    @Test("the app group is named without a team id, so the repository carries no team id")
    func accessGroupIsAnAppGroup() {
        #expect(DeviceCredentials.accessGroup == "group.live.discomarder.memosng")
        #expect(DeviceCredentials.service == "live.discomarder.memosng")
    }
}
