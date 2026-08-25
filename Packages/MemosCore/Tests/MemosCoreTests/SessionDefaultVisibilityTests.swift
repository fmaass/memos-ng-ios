import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let patchSettingsOperation = "update_settings_api_settings_patch"
private let getSettingsOperation = "get_settings_api_settings_get"

/// One `/api/settings` payload. At file scope rather than on the suite because the stub transport
/// is called off the main actor, and a helper isolated to a `@MainActor` suite cannot be reached
/// from there.
/// The patch body as its fields.
///
/// PARSED rather than matched as a substring: the generated client pretty-prints what it encodes
/// (`{\n  "default_visibility" : "PRIVATE"\n}`), so a literal comparison would be asserting the
/// encoder's whitespace instead of the contract. Comparing the whole dictionary also says the
/// thing two `!contains` checks only implied — that this field is the ONLY one sent.
private func patchFields(_ payload: String) -> [String: String]? {
    (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: String]
}

private func settingsBody(_ visibility: String, avatar: String = "null") -> String {
    """
    {"default_visibility":"\(visibility)","theme":"dark","avatar":\(avatar)}
    """
}

/// Changing the account's default visibility from the Settings screen.
///
/// The transport is substituted and the store is not: what these assert is the request
/// `SessionStore` actually builds, the body it actually sends and the answer it actually adopts.
/// A hand-written stand-in for `APIProtocol` would assert only that this file agrees with itself.
@MainActor
@Suite("Setting the account's default visibility")
struct SessionDefaultVisibilityTests {
    private func signedIn(
        handler: @escaping StubTransport.Handler
    ) async -> SessionStore {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    /// The whole point of the section: the choice reaches the server, in the field the contract
    /// names, and it is the ONLY field sent — the patch is partial, so naming `theme` or `avatar`
    /// here would turn a change of one setting into a write of three.
    @Test("the chosen visibility is PATCHed, and nothing else is")
    func theChoiceIsSent() async throws {
        let sent = LockedValue<String?>(nil)
        let session = await signedIn { _, body, operation in
            guard operation == patchSettingsOperation else { return Stub.json(Stub.user) }
            if let body {
                let data = try await Data(collecting: body, upTo: 4096)
                sent.set(String(decoding: data, as: UTF8.self))
            }
            return Stub.json(settingsBody("PRIVATE"))
        }

        let saved = await session.setDefaultVisibility(.private)

        #expect(saved)
        let payload = try #require(sent.get())
        // The patch is partial and the server applies only what it is given, so sending `theme`
        // or `avatar` — even with what it just said they were — would turn a change of one
        // setting into a write of three. This equality is what forbids that.
        #expect(patchFields(payload) == ["default_visibility": "PRIVATE"])
        #expect(session.defaultVisibility == .private)
    }

    /// Both offered states, each sent under its own wire name. One case per input category rather
    /// than a happy path: a mapping tested in one direction only is a mapping that can be
    /// half-wrong forever.
    @Test("each offered visibility round-trips under its own wire name")
    func bothStatesRoundTrip() async throws {
        for (visibility, wire) in [(MemoVisibility.public, "PUBLIC"), (.private, "PRIVATE")] {
            let sent = LockedValue<String?>(nil)
            let session = await signedIn { _, body, operation in
                guard operation == patchSettingsOperation else { return Stub.json(Stub.user) }
                if let body {
                    let data = try await Data(collecting: body, upTo: 4096)
                    sent.set(String(decoding: data, as: UTF8.self))
                }
                return Stub.json(settingsBody(wire))
            }

            let saved = await session.setDefaultVisibility(visibility)
            #expect(saved)

            let payload = try #require(sent.get())
            #expect(patchFields(payload) == ["default_visibility": wire])
            #expect(session.defaultVisibility == visibility)
        }
    }

    /// The SERVER is the authority on what the setting now is, not the tap. If the two disagree —
    /// another device wrote it a moment earlier, or the server normalised the value — what the
    /// screen shows afterwards is the server's answer, because that is what the next memo will
    /// actually get.
    @Test("what is displayed afterwards is the server's answer, not the request")
    func theServerHasTheLastWord() async {
        let session = await signedIn { _, _, operation in
            operation == patchSettingsOperation
                ? Stub.json(settingsBody("PUBLIC")) : Stub.json(Stub.user)
        }

        let saved = await session.setDefaultVisibility(.private)
        #expect(saved)

        #expect(session.defaultVisibility == .public)
    }

    /// A refusal must not leave the screen claiming a change that did not happen.
    @Test("a rejected change leaves the default exactly as it was")
    func aRefusalChangesNothing() async {
        let session = await signedIn { _, _, operation in
            switch operation {
            case getSettingsOperation: return Stub.json(settingsBody("PUBLIC"))
            case patchSettingsOperation: return Stub.empty(.unprocessableContent)
            default: return Stub.json(Stub.user)
            }
        }
        await session.loadSettings()
        #expect(session.defaultVisibility == .public)

        let saved = await session.setDefaultVisibility(.private)

        #expect(!saved)
        #expect(session.defaultVisibility == .public)
        // A refused setting is not a refused credential.
        #expect(session.state.user != nil)
    }

    /// A 401 is the server saying this credential is dead, wherever it arrives — the settings
    /// write is not an exception to the rule that ends the session.
    @Test("a 401 from the write ends the session like any other")
    func anUnauthorisedWriteEndsTheSession() async {
        let session = await signedIn { _, _, operation in
            operation == patchSettingsOperation
                ? Stub.empty(.unauthorized) : Stub.json(Stub.user)
        }

        let saved = await session.setDefaultVisibility(.private)

        #expect(!saved)
        #expect(session.state.user == nil)
    }

    /// Nothing is written while there is nobody to write it for.
    @Test("a signed-out session sends nothing")
    func signedOutSendsNothing() async {
        let asked = LockedValue<Bool>(false)
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, operation in
                    if operation == patchSettingsOperation { asked.set(true) }
                    return Stub.json(Stub.user)
                }
            }
        )

        let saved = await session.setDefaultVisibility(.private)

        #expect(!saved)
        #expect(!asked.get())
    }
}

/// The account's picture travels on the same read as its default, and has the same lifetime: it
/// belongs to the account, so it may not survive into the next one.
@MainActor
@Suite("The account's avatar")
struct SessionAvatarTests {
    @Test("the avatar is read from /api/settings and kept")
    func avatarIsRead() async {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, operation in
                    operation == getSettingsOperation
                        ? Stub.json(
                            """
                            {"default_visibility":"PUBLIC","theme":"dark",\
                            "avatar":"data:image/png;base64,AAAA"}
                            """
                        )
                        : Stub.json(Stub.user)
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(session.avatar == nil)

        await session.loadSettings()

        #expect(session.avatar == "data:image/png;base64,AAAA")
    }

    /// Carrying a face into the next sign-in would put one account's picture over another's name.
    @Test("signing out takes the picture with it")
    func signOutClearsTheAvatar() async {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, operation in
                    operation == getSettingsOperation
                        ? Stub.json(
                            """
                            {"default_visibility":"PUBLIC","theme":"dark",\
                            "avatar":"data:image/png;base64,AAAA"}
                            """
                        )
                        : Stub.json(Stub.user)
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        await session.loadSettings()
        #expect(session.avatar != nil)

        await session.signOutWithoutRevoking()

        #expect(session.avatar == nil)
    }
}
