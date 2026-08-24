import Foundation
import MemosCore
import Security
import Testing

/// The wrapper against the real Keychain — the point is that the app's accessibility choice and
/// the update-or-insert path actually work, which only a real round trip can show.
@Suite("Keychain", .serialized)
struct KeychainTests {
    // Named, like every other keychain query in the app: `Keychain` has no ungrouped form any
    // more, because a query with no access group reaches into every group the app can see.
    private let keychain = Keychain(
        service: "live.discomarder.memosng.tests",
        accessGroup: KeychainAccessGroup.appDefault ?? "live.discomarder.memosng.unresolved"
    )
    private let account = "round-trip"

    @Test("stores, reads back, overwrites and removes")
    func roundTrip() throws {
        try keychain.remove(account)

        #expect(try keychain.string(for: account) == nil)

        try keychain.set("memos_pat_first", for: account)
        #expect(try keychain.string(for: account) == "memos_pat_first")

        // Signing in again must replace the credential, not fail with a duplicate.
        try keychain.set("memos_pat_second", for: account)
        #expect(try keychain.string(for: account) == "memos_pat_second")

        try keychain.remove(account)
        #expect(try keychain.string(for: account) == nil)
    }

    @Test("removing something that is not there is not a failure")
    func removeIsIdempotent() throws {
        try keychain.remove("never-stored")
        try keychain.remove("never-stored")
    }

    /// Corruption is not absence. An item that IS there and cannot be turned back into a token is
    /// a storage failure — answering `nil` for it would tell a session that nobody is signed in,
    /// on the evidence that something unreadable is stored.
    @Test("bytes that are not a token are raised, not reported as nothing stored")
    func corruptionIsNotAbsence() throws {
        let account = "not-utf8"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychain.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: keychain.accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        // A lone continuation byte: valid bytes, and not a valid UTF-8 sequence.
        insert[kSecValueData as String] = Data([0xFF, 0xFE, 0x80])
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #expect(SecItemAdd(insert as CFDictionary, nil) == errSecSuccess)
        defer { SecItemDelete(query as CFDictionary) }

        #expect(throws: Keychain.Failure.dataNotUTF8) {
            _ = try keychain.string(for: account)
        }
    }
}
