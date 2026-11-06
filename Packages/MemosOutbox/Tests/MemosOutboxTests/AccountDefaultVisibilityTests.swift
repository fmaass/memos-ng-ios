import Foundation
import MemosOutbox
import Testing

/// The account's default visibility as the app publishes it beside the licence (MEMNG-972), so the
/// share sheet can name it. The file is the only thing the app and the extension share, so every
/// assertion reads it back through a store, the way the other process does.
@Suite("The default visibility published beside the licence")
struct AccountDefaultVisibilityTests {
    private func withStore(_ body: (OutboxAccountStore, URL) throws -> Void) throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try body(OutboxAccountStore(root: root.appending(path: "outbox")), root)
    }

    /// What the other process reads: the default under whatever licence stands right now.
    private func standingDefault(_ store: OutboxAccountStore) -> String? {
        store.currentLicence().flatMap { store.defaultVisibility(under: $0) }
    }

    @Test("a default published for the standing licence is what the extension reads back")
    func roundTrips() throws {
        try withStore { store, root in
            store.publish(Fixture.binding())
            store.publishDefaultVisibility("PRIVATE", for: Fixture.binding())
            let other = OutboxAccountStore(root: root.appending(path: "outbox"))
            #expect(standingDefault(other) == "PRIVATE")
            store.publishDefaultVisibility(nil, for: Fixture.binding())
            #expect(standingDefault(other) == nil, "an unknown default is written as unknown")
        }
    }

    /// The app republishes the same pair at every foreground revalidation; that must not blank
    /// the default it read a minute ago. A new grant is an account change to the extension, and
    /// the previous grant's default is not this one's.
    @Test("a republish over the same grant keeps the default; a new grant starts without one")
    func defaultFollowsTheGrant() throws {
        try withStore { store, _ in
            store.publish(Fixture.binding())
            store.publishDefaultVisibility("PROTECTED", for: Fixture.binding())
            store.publish(Fixture.binding())
            #expect(standingDefault(store) == "PROTECTED", "a republish blanked the default")

            store.publish(Fixture.binding(owner: "someone-else"))
            #expect(standingDefault(store) == nil, "another account inherited the default")

            store.publishDefaultVisibility("PUBLIC", for: Fixture.binding(owner: "someone-else"))
            try store.clear()
            store.publish(Fixture.binding(owner: "someone-else"))
            #expect(standingDefault(store) == nil, "a re-grant to the same account kept it")
        }
    }

    @Test("a default is written onto the standing licence only, and never creates one")
    func writesOnlyOntoTheStandingLicence() throws {
        try withStore { store, root in
            store.publishDefaultVisibility("PUBLIC", for: Fixture.binding())
            #expect(store.currentLicence() == nil, "a default minted a licence nobody granted")
            let file = root.appending(path: "outbox/account.json")
            #expect(!FileManager.default.fileExists(atPath: file.path))

            store.publish(Fixture.binding())
            store.publishDefaultVisibility("PRIVATE", for: Fixture.binding())
            store.publishDefaultVisibility("PUBLIC", for: Fixture.binding(owner: "someone-else"))
            #expect(standingDefault(store) == "PRIVATE", "another account's default was written")
            #expect(store.current() == Fixture.binding())
        }
    }

    /// A default is a setting, not a grant of permission: folding it into the licence would make
    /// every change in Settings refuse the share that was waiting its turn under that licence.
    @Test("publishing a default leaves the licence exactly as it was")
    func licenceIsUnchanged() throws {
        try withStore { store, root in
            store.publish(Fixture.binding())
            let before = try #require(store.currentLicence())
            store.publishDefaultVisibility("PRIVATE", for: Fixture.binding())
            #expect(store.currentLicence() == before)

            let data = try Data(contentsOf: root.appending(path: "outbox/account.json"))
            let fields = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: String]
            )
            let expected = ["defaultVisibility", "incarnation", "ownerSubject", "serverBaseURL"]
            #expect(fields.keys.sorted() == expected)
        }
    }

    /// The reader's half of the fence: a sheet that resolved its route under one licence never
    /// shows a default published under another, even when the file has moved on in between.
    @Test("a default reads only under the licence it was published with")
    func readsOnlyUnderItsOwnLicence() throws {
        try withStore { store, _ in
            store.publish(Fixture.binding())
            let opened = try #require(store.currentLicence())
            try store.clear()
            store.publish(Fixture.binding())
            store.publishDefaultVisibility("PUBLIC", for: Fixture.binding())
            #expect(store.defaultVisibility(under: opened) == nil, "a re-granted licence's default")
            #expect(standingDefault(store) == "PUBLIC", "the control: the standing one reads")
        }
    }
}
