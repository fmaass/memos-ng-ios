import Foundation
import MemosOutbox
import MemosShareKit
import Testing

/// The share sheet's "Account default" option names the account's current default (MEMNG-972).
@Suite("The Account default option names the account's default")
struct AccountDefaultLabelTests {
    @Test(
        "each published default is named in the picker's own words",
        arguments: [
            ("PRIVATE", "Account default (Private)"),
            ("PROTECTED", "Account default (Just us)"),
            ("PUBLIC", "Account default (Public)"),
        ]
    )
    func namesThePublishedDefault(wire: String, label: String) {
        #expect(ShareComposition.accountDefaultLabel(published: wire) == label)
    }

    /// Nothing published, or a wire name a newer server invented: the option says no more than
    /// it knows, rather than promising an audience.
    @Test("an unknown default names nothing")
    func unknownNamesNothing() {
        #expect(ShareComposition.accountDefaultLabel(published: nil) == "Account default")
        #expect(ShareComposition.accountDefaultLabel(published: "FRIENDS") == "Account default")
    }

    /// The whole path the extension takes: the app publishes the licence and the default into the
    /// app group, the sheet resolves its route from the files, reads the default under that very
    /// licence and names it.
    @Test("the default the app published beside the licence is the one the option names")
    func namesWhatTheAppPublished() throws {
        let group = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: group) }
        let app = OutboxAccountStore(root: group.appending(path: "outbox"))
        app.publish(Fixture.binding())
        app.publishDefaultVisibility("PRIVATE", for: Fixture.binding())

        let sheet = OutboxAccountStore(root: group.appending(path: "outbox"))
        let route = try #require(ShareRoute.resolve(member: sheet.currentLicence(), guest: nil))
        let published = sheet.defaultVisibility(under: route.licence)
        let label = ShareComposition.accountDefaultLabel(published: published)
        #expect(label == "Account default (Private)")
    }
}
