import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// A server that knows who is signed in, under the display name it was given, and nothing else.
/// Every other read fails plainly: what is under test is the account row, not what the rest of
/// the screen loads.
private nonisolated final class AccountRowTransport: ClientTransport, Sendable {
    private let displayName: String

    init(displayName: String) { self.displayName = displayName }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard operationID == "whoami_api_auth_user_get" else {
            return (HTTPResponse(status: .notFound), nil)
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (
            response,
            HTTPBody(
                """
                {"subject":"sub-7f3a","display_name":"\(displayName)",\
                "email":"fabian@example.invalid","role":"user","auth_kind":"oidc"}
                """
            )
        )
    }
}

/// The keychain, in memory.
private final class AccountRowCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func set(_ value: String, for account: String) async throws {
        lock.withLock { values[account] = value }
    }

    func string(for account: String) async throws -> String? {
        lock.withLock { values[account] }
    }

    func remove(_ account: String) async throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

/// The Settings account row as it is drawn: the real `SettingsView` over a real `SessionStore`
/// signed in through the real generated client, for an account whose display name came back
/// blank. The row names it by its address — not a bare "Signed in", which is what it read while
/// `User.name` handed over the blank.
///
/// The avatar's initials are not read here: the avatar is hidden from the accessibility tree the
/// probe reads, so they are held by `SignOutFlowTests` over the same `User.name` instead.
@MainActor
@Suite("The Settings account row")
struct SettingsAccountRowRenderTests {
    @Test(
        "an account with a blank display name is headed by its address",
        arguments: ["", "  "]
    )
    func aBlankDisplayNameIsHeadedByTheAddress(blank: String) async {
        let session = SessionStore(
            credentials: AccountRowCredentials(),
            makeClient: { configuration, credential in
                APIClientFactory.make(
                    configuration: configuration,
                    credential: credential,
                    transport: AccountRowTransport(displayName: blank)
                )
            },
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            // Its own clock, so a sign-in here rotates nothing another suite is counting on.
            identity: MediaIdentity()
        )
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_accountrow")
        #expect(session.state.user?.displayName == blank, "precondition: signed in, name blank")

        let labels = ScreenProbe.labels(
            of: SettingsView(signOut: SignOutConversation(), avatar: nil).environment(session)
        )

        // The control: the row is on the screen at all, so a miss below is about its words.
        #expect(labels.contains { $0.contains("Signed in") }, "the account row was not drawn")
        #expect(
            labels.contains { $0.contains("Signed in as fabian@example.invalid") },
            "display name \(blank.debugDescription) did not head the row with the address"
        )
    }
}
