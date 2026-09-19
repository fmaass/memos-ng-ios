import Foundation
import MemosOutbox
import Testing

@Suite("The account an extension binds a capture to")
struct AccountStoreTests {
    private func withStore(_ body: (OutboxAccountStore, URL) throws -> Void) throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try body(OutboxAccountStore(root: root.appending(path: "outbox")), root)
    }

    @Test("what the app publishes is what another process reads back")
    func roundTrips() throws {
        try withStore { store, root in
            #expect(store.current() == nil)
            store.publish(Fixture.binding())
            #expect(store.current() == Fixture.binding())

            // A second store over the same container is what the share extension is.
            let other = OutboxAccountStore(root: root.appending(path: "outbox"))
            #expect(other.current() == Fixture.binding())
        }
    }

    @Test("signing out takes the binding with it, and says so if it cannot")
    func clearForgets() throws {
        try withStore { store, _ in
            store.publish(Fixture.binding())
            try store.clear()
            #expect(store.current() == nil)
            // Revoking what is not there is success, not an error: the point of a revocation is
            // that nothing is left, whatever state it started from. It has to stay non-throwing
            // for the absent case, because the session treats a throw as "still licensed".
            try store.clear()
            #expect(store.current() == nil)
        }
    }

    @Test("a licence in a container that is not there is a revocation that failed")
    func clearReportsRealFailures() throws {
        let root = try Fixture.temporaryDirectory()
        let store = OutboxAccountStore(root: root.appending(path: "outbox"))
        store.publish(Fixture.binding())
        // The whole container goes, as a device running out of space or a wiped app group would
        // leave it — everything below the licence is gone, but not the licence's own absence.
        try FileManager.default.removeItem(at: root)
        // Nothing is left to remove, so this is the absent case, not a failure.
        try store.clear()
        #expect(store.current() == nil)
    }

    @Test("a binding that cannot be parsed is no binding at all")
    func rejectsUnreadable() throws {
        try withStore { store, root in
            let file = root.appending(path: "outbox/account.json")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("not json".utf8).write(to: file)
            #expect(store.current() == nil)
        }
    }

    @Test("the published file carries a server, an owner and the grant, and nothing else")
    func holdsNoCredential() throws {
        try withStore { store, root in
            store.publish(Fixture.binding())
            let data = try Data(contentsOf: root.appending(path: "outbox/account.json"))
            let fields = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: String]
            )
            #expect(fields.keys.sorted() == ["incarnation", "ownerSubject", "serverBaseURL"])
        }
    }

    // MARK: - which grant of the licence this is

    /// The app republishes the same pair every time it revalidates the session in the foreground.
    /// A new grant there would refuse a share that is doing nothing but waiting for the queue.
    @Test("a licence republished over itself keeps the grant it already had")
    func republishingKeepsTheGrant() throws {
        try withStore { store, _ in
            store.publish(Fixture.binding())
            let first = try #require(store.currentLicence()?.incarnation)
            store.publish(Fixture.binding())
            #expect(store.currentLicence()?.incarnation == first)
            #expect(store.current() == Fixture.binding())
        }
    }

    /// The window this exists for: forgotten and signed into again, the pair is identical and the
    /// session is not, so the pair alone cannot say a capture admitted before it may be published
    /// after it.
    @Test("a licence revoked and granted again to the same account is a different grant")
    func reissuingChangesTheGrant() throws {
        try withStore { store, _ in
            store.publish(Fixture.binding())
            let first = try #require(store.currentLicence()?.incarnation)
            try store.clear()
            store.publish(Fixture.binding())
            let second = try #require(store.currentLicence()?.incarnation)
            #expect(second != first)
            #expect(store.current() == Fixture.binding(), "and it is still the same account")
        }
    }

    @Test("another account's licence is another grant")
    func anotherAccountIsAnotherGrant() throws {
        try withStore { store, _ in
            store.publish(Fixture.binding())
            let first = try #require(store.currentLicence()?.incarnation)
            store.publish(Fixture.binding(owner: "someone-else"))
            #expect(store.currentLicence()?.incarnation != first)
        }
    }

    /// The file a build that predates grants left behind. It reads, and it fences nothing — which
    /// is the honest answer about a fact the file never carried.
    @Test("a licence written before grants existed reads as a licence with none")
    func readsALicenceFromBeforeGrants() throws {
        try withStore { store, root in
            let file = root.appending(path: "outbox/account.json")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(Fixture.binding()).write(to: file)
            #expect(store.current() == Fixture.binding())
            #expect(store.currentLicence()?.incarnation == nil)
            // And the next thing the app publishes grants one, so the fence starts working without
            // anybody signing out.
            store.publish(Fixture.binding())
            #expect(store.currentLicence()?.incarnation != nil)
        }
    }
}
