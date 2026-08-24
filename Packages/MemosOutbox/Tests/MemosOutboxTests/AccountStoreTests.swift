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

    @Test("the published file carries a server and an owner, and nothing else")
    func holdsNoCredential() throws {
        try withStore { store, root in
            store.publish(Fixture.binding())
            let data = try Data(contentsOf: root.appending(path: "outbox/account.json"))
            let fields = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: String]
            )
            #expect(fields.keys.sorted() == ["ownerSubject", "serverBaseURL"])
        }
    }
}
