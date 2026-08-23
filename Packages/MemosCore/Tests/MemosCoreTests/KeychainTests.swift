import Foundation
import MemosCore
import Testing

/// The wrapper against the real Keychain — the point is that the app's accessibility choice and
/// the update-or-insert path actually work, which only a real round trip can show.
@Suite("Keychain", .serialized)
struct KeychainTests {
    private let keychain = Keychain(service: "live.discomarder.memosng.tests")
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
}
