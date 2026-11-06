import Foundation
import HTTPTypes
import MemosOutbox
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let patchSettings = "update_settings_api_settings_patch"
private let getSettings = "get_settings_api_settings_get"

private func settingsBody(_ visibility: String) -> String {
    """
    {"default_visibility":"\(visibility)","theme":"dark","avatar":null}
    """
}

/// Whoami for a named subject, so a test can sign a second, different account in.
private func user(_ subject: String) -> String {
    """
    {"subject":"\(subject)","display_name":"\(subject)","email":"\(subject)@example.invalid",\
    "role":"admin","auth_kind":"oidc"}
    """
}

/// The account's default visibility as the session publishes it into the licence file the share
/// extension reads (MEMNG-972).
///
/// The transport is scripted and the store is real, and so is the licence file: every assertion
/// reads it back through a second `OutboxAccountStore` over the same directory, which is exactly
/// what the share extension is.
@MainActor
@Suite("The default visibility reaches the share extension's licence file")
struct SessionDefaultPublishTests {
    private struct Rig {
        let session: SessionStore
        let root: URL
        /// The extension's view of the same directory.
        var sheet: OutboxAccountStore { OutboxAccountStore(root: root) }
        /// What the share sheet would name: the default under the licence standing now.
        var published: String? {
            sheet.currentLicence().flatMap { sheet.defaultVisibility(under: $0) }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeRig(
        subject: LockedValue<String> = LockedValue("fabian"),
        handler: @escaping @Sendable (String, HTTPBody?) async throws -> (HTTPResponse, HTTPBody?)?
    ) async -> Rig {
        let root = FileManager.default.temporaryDirectory.appending(path: "default-\(UUID())")
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(
                    token: token,
                    handler: { _, body, operation in
                        if let scripted = try await handler(operation, body) { return scripted }
                        return Stub.json(user(subject.get()))
                    }
                )
            },
            account: OutboxAccountStore(root: root)
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return Rig(session: session, root: root)
    }

    @Test("the default the server names is published beside the licence")
    func readIsPublished() async {
        let rig = await makeRig { operation, _ in
            operation == getSettings ? Stub.json(settingsBody("PROTECTED")) : nil
        }
        defer { rig.cleanUp() }
        #expect(rig.published == nil, "precondition: nothing is published before the read")

        await rig.session.loadSettings()

        #expect(rig.session.defaultVisibility == .protected)
        #expect(rig.published == "PROTECTED")
    }

    /// The PATCH carries the one field it changes, and what is published afterwards is the
    /// server's answer out of that PATCH.
    @Test("a saved default is PATCHed alone, and the server's answer is published")
    func savedDefaultIsPublished() async throws {
        let sent = LockedValue<[String: String]?>(nil)
        let rig = await makeRig { operation, body in
            guard operation == patchSettings else { return nil }
            let data = try await Stub.bytes(body)
            sent.set((try? JSONSerialization.jsonObject(with: data)) as? [String: String])
            return Stub.json(settingsBody("PRIVATE"))
        }
        defer { rig.cleanUp() }

        let saved = await rig.session.setDefaultVisibility(.private)

        #expect(saved)
        #expect(sent.get() == ["default_visibility": "PRIVATE"])
        #expect(rig.session.defaultVisibility == .private)
        #expect(rig.published == "PRIVATE")
    }

    @Test("a refused PATCH leaves the shown and the published default at the server's")
    func refusedSaveChangesNothing() async {
        let rig = await makeRig { operation, _ in
            switch operation {
            case getSettings: Stub.json(settingsBody("PUBLIC"))
            case patchSettings: Stub.empty(.unprocessableContent)
            default: nil
            }
        }
        defer { rig.cleanUp() }
        await rig.session.loadSettings()
        #expect(rig.published == "PUBLIC", "precondition: the server's default was published")

        let saved = await rig.session.setDefaultVisibility(.private)

        #expect(!saved)
        #expect(rig.session.defaultVisibility == .public)
        #expect(rig.published == "PUBLIC")
    }

    /// «Every credential- or identity-scoped read is epoch-fenced»: a settings read issued for one
    /// account and answered after another has signed in is judged against the account that ASKED.
    @Test("a read issued before another account signed in never reaches that account's file")
    func staleReadNeverCrossesAccounts() async throws {
        let subject = LockedValue("fabian")
        let entered = TripLatch()
        let release = TripLatch()
        let reads = LockedValue(0)
        let rig = await makeRig(subject: subject) { operation, _ in
            guard operation == getSettings else { return nil }
            let first = reads.get() == 0
            reads.set(reads.get() + 1)
            guard first else { return Stub.json(settingsBody("PROTECTED")) }
            entered.open()
            _ = await release.wait()
            return Stub.json(settingsBody("PUBLIC"))
        }
        defer { rig.cleanUp() }

        async let stale: Void = rig.session.loadSettings()
        #expect(await entered.wait(), "the first account's read never reached the wire")
        subject.set("someone-else")
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_other")
        let licence = try #require(rig.sheet.currentLicence())
        #expect(licence.binding.ownerSubject == "someone-else", "precondition: B is signed in")
        release.open()
        await stale

        #expect(rig.session.defaultVisibility == nil, "A's default was adopted for B")
        #expect(rig.published == nil, "A's default was published onto B's licence")

        // The control: B's own read does publish.
        await rig.session.loadSettings()
        #expect(rig.published == "PROTECTED")
    }

    /// The write's half of the identity fence: a PATCH asked for by account A and answered after
    /// B has signed in is judged against A's generation, so its answer reaches neither B's screen
    /// nor B's licence file.
    @Test("a save answered after another account signed in publishes nothing onto that account")
    func staleSaveNeverCrossesAccounts() async throws {
        let subject = LockedValue("fabian")
        let entered = TripLatch()
        let release = TripLatch()
        let rig = await makeRig(subject: subject) { operation, _ in
            switch operation {
            case patchSettings:
                entered.open()
                _ = await release.wait()
                return Stub.json(settingsBody("PRIVATE"))
            case getSettings:
                return Stub.json(settingsBody("PROTECTED"))
            default:
                return nil
            }
        }
        defer { rig.cleanUp() }

        async let stale = rig.session.setDefaultVisibility(.private)
        #expect(await entered.wait(), "the first account's save never reached the wire")
        subject.set("someone-else")
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_other")
        let licence = try #require(rig.sheet.currentLicence())
        #expect(licence.binding.ownerSubject == "someone-else", "precondition: B is signed in")
        await rig.session.loadSettings()
        #expect(rig.published == "PROTECTED", "precondition: B's own default was published")
        release.open()

        #expect(await stale == false, "A's save answered as adopted in B's session")
        #expect(rig.session.defaultVisibility == .protected, "A's answer replaced B's default")
        #expect(rig.published == "PROTECTED", "A's answer was published onto B's licence")
    }

    /// «A store serializes its own mutations»: a read that was already out when a save went on
    /// the wire carries the default from before the save, and must not put it back afterwards —
    /// neither on the screen nor in the share extension's file.
    @Test("a read that outlived a save does not undo the saved default")
    func readOutlivedBySaveDoesNotUndoIt() async {
        let entered = TripLatch()
        let release = TripLatch()
        let rig = await makeRig { operation, _ in
            switch operation {
            case getSettings:
                entered.open()
                _ = await release.wait()
                return Stub.json(settingsBody("PUBLIC"))
            case patchSettings:
                return Stub.json(settingsBody("PRIVATE"))
            default:
                return nil
            }
        }
        defer { rig.cleanUp() }

        async let read: Void = rig.session.loadSettings()
        #expect(await entered.wait(), "the read never reached the wire")
        #expect(await rig.session.setDefaultVisibility(.private))
        release.open()
        await read

        #expect(rig.session.defaultVisibility == .private, "the old read put PUBLIC back")
        #expect(rig.published == "PRIVATE", "the old read published PUBLIC over the save")
    }
}
