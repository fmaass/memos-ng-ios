import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Nonisolated because the transport below is: a `ClientTransport` is called off the main actor
/// by the generated client, and what it reads has to be readable from there.
private enum Wire {
    nonisolated static let whoami = "whoami_api_auth_user_get"
    /// The list read — the request a recovery is supposed to cause EXACTLY one of. Counted by its
    /// own operation and not as "anything that is not a whoami", because the screen's first task
    /// also reads the account's settings, and a counter that lumped the two together would say a
    /// recovery read the list when it had not.
    nonisolated static let listMemos = "list_memos_api_memos_get"
}

/// The transport the app's own generated client is built over, scripted and counted.
///
/// A real `ClientTransport`, not a substituted store: what is under test is the whole composition
/// — the store builds the request, the middleware attaches the token, the generated client decodes
/// the answer — and a stand-in for any of those would prove nothing about the path a regain takes.
final class ScriptedWireTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [String] = []

    var whoamis: Int { lock.withLock { operations.count(where: { $0 == Wire.whoami }) } }
    var pages: Int { lock.withLock { operations.count(where: { $0 == Wire.listMemos }) } }
    var seen: [String] { lock.withLock { operations } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { operations.append(operationID) }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        let payload: String
        switch operationID {
        case Wire.whoami:
            payload = """
                {"subject":"fabian","display_name":"Fabian","email":"f@example.invalid",\
                "role":"admin","auth_kind":"oidc"}
                """
        case Wire.listMemos:
            payload = """
                {"items":[],"nextCursor":null,"totalCount":null}
                """
        default:
            // The account's settings, which the screen's first task reads beside the list.
            payload = """
                {"default_visibility":"PRIVATE","theme":"system","avatar":null}
                """
        }
        return (response, HTTPBody(payload))
    }
}

/// The keychain, in memory.
private final class ComposedCredentials: CredentialStore, @unchecked Sendable {
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

/// The monitor's two halves, scripted separately — the count a check reads as it is ISSUED, and a
/// delivery that can arrive at any time afterwards.
final class ComposedRoutes: RouteStatusMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var losses = 0
    private let events: AsyncStream<RouteRegain>.Continuation
    let regains: AsyncStream<RouteRegain>

    init() {
        var events: AsyncStream<RouteRegain>.Continuation!
        regains = AsyncStream<RouteRegain> { events = $0 }
        self.events = events
    }

    func lossesSeen() -> Int {
        lock.withLock { losses }
    }

    @discardableResult
    func countLoss() -> Int {
        lock.withLock {
            losses += 1
            return losses
        }
    }

    func deliverRegain(closing ordinal: Int) {
        events.yield(RouteRegain(lossOrdinal: ordinal))
    }
}

/// One regain, one read of the list, one signal to the pictures — counted through the REAL screen.
///
/// The Core suite holds the store to one recovery per regain in every order the events can arrive
/// in. This one holds the rest of the path: the timeline screen is hosted in a key window, its
/// `reloadsOnRecovery` observes the session's counter, its `load()` reads the list over the app's
/// own client and publishes the media signal. Nothing here is a double except the transport under
/// the client and the path monitor above the store.
@MainActor
@Suite(.serialized)
struct ComposedRecoveryTests {
    private let transport = ScriptedWireTransport()
    private let routes = ComposedRoutes()

    private func makeSession() -> SessionStore {
        SessionStore(
            credentials: ComposedCredentials(),
            makeClient: { [transport] configuration, credential in
                APIClientFactory.make(
                    configuration: configuration,
                    credential: credential,
                    transport: transport
                )
            },
            // Parked rather than real: a retry rung firing inside a case would be a second whoami
            // nobody asked for, and what is counted here is what the REGAIN caused.
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            routes: routes
        )
    }

    /// Lets SwiftUI notice a change and lets the task it hands the reload to run.
    private func settle(_ host: UIHostingController<some View>, turns: Int = 40) async {
        for _ in 0..<turns {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func settle(
        _ host: UIHostingController<some View>,
        until condition: () -> Bool,
        turns: Int = 200
    ) async {
        for _ in 0..<turns where !condition() {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The signed-in app on screen, with its first read already done.
    private func hosted() async -> (
        session: SessionStore, host: UIHostingController<some View>, window: UIWindow
    ) {
        let session = makeSession()
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_composed")
        let host = UIHostingController(rootView: TimelineView().environment(session))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        await settle(host, until: { self.transport.pages >= 1 })
        await settle(host, turns: 8)
        return (session, host, window)
    }

    private func tearDown(_ host: UIHostingController<some View>, _ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    @Test("a regain while the session awaits confirmation asks once, reads once and signals once")
    func aRegainWhileAwaitingConfirmation() async {
        let (session, host, window) = await hosted()
        defer { tearDown(host, window) }
        #expect(transport.pages == 1, "precondition: the screen read the list once on appearing")

        session.noteTransportFailure(.offline, issuedUnder: session.activeHandle!.generation)
        let whoamisBefore = transport.whoamis
        let pagesBefore = transport.pages
        let signalsBefore = MediaRetrySignal.shared.publications
        let ordinal = routes.countLoss()

        routes.deliverRegain(closing: ordinal)
        await settle(host, until: { session.reachabilityRecoveries == 1 })
        await settle(host, until: { self.transport.pages > pagesBefore })
        await settle(host, turns: 12)

        #expect(session.reachabilityRecoveries == 1)
        #expect(transport.whoamis == whoamisBefore + 1, "the regain asked more than once")
        #expect(transport.pages == pagesBefore + 1, "the recovery read the list more than once")
        #expect(
            MediaRetrySignal.shared.publications == signalsBefore + 1,
            "the pictures were signalled a number of times that is not one"
        )
    }

    @Test("a regain while the session is confirmed reads once, signals once and asks nothing")
    func aRegainWhileVerified() async {
        let (session, host, window) = await hosted()
        defer { tearDown(host, window) }
        #expect(session.verification == .verified, "precondition: the session is confirmed")

        let whoamisBefore = transport.whoamis
        let pagesBefore = transport.pages
        let signalsBefore = MediaRetrySignal.shared.publications
        let ordinal = routes.countLoss()

        routes.deliverRegain(closing: ordinal)
        await settle(host, until: { session.reachabilityRecoveries == 1 })
        await settle(host, until: { self.transport.pages > pagesBefore })
        await settle(host, turns: 12)

        #expect(
            transport.whoamis == whoamisBefore,
            "a confirmed session was asked to confirm again"
        )
        #expect(transport.pages == pagesBefore + 1, "the recovery read the list more than once")
        #expect(
            MediaRetrySignal.shared.publications == signalsBefore + 1,
            "the pictures were signalled a number of times that is not one"
        )
    }
}
