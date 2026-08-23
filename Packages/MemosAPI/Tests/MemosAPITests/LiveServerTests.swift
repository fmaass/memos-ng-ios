import Foundation
import MemosAPI
import Testing

/// Credentials for the one test that talks to a real server.
///
/// `xcodebuild test` does not hand the host's environment to a process running in the simulator,
/// but it does forward variables prefixed `TEST_RUNNER_` with the prefix stripped — so the
/// gate is run as `TEST_RUNNER_MEMOS_SERVER=… TEST_RUNNER_MEMOS_PAT=… bin/mac-gate.sh`.
/// With neither set
/// the suite is skipped, which is what every ordinary run does: a gate that needs a live server and
/// a live token is not a gate.
enum LiveServer {
    static var configuration: (server: String, token: String)? {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["MEMOS_SERVER"], !server.isEmpty,
            let token = environment["MEMOS_PAT"], !token.isEmpty
        else { return nil }
        return (server, token)
    }

    static var isConfigured: Bool { configuration != nil }
}

@Suite("live server round trip", .enabled(if: LiveServer.isConfigured))
struct LiveServerTests {
    @Test("GET /api/memos answers 200 with at least one memo")
    func listMemos() async throws {
        let credentials = try #require(LiveServer.configuration)
        let configuration = try #require(ServerConfiguration(serverAddress: credentials.server))
        let client = APIClientFactory.make(
            configuration: configuration,
            token: { credentials.token }
        )

        let response = try await client.listMemosApiMemosGet(.init(query: .init(limit: 5)))
        guard case .ok(let ok) = response else {
            Issue.record("expected 200, got \(response)")
            return
        }
        let page = try ok.body.json
        #expect(!page.items.isEmpty)
        #expect(page.items.allSatisfy { !$0.uid.isEmpty })
    }

    @Test("the same token answers /api/auth/user")
    func whoami() async throws {
        let credentials = try #require(LiveServer.configuration)
        let configuration = try #require(ServerConfiguration(serverAddress: credentials.server))
        let client = APIClientFactory.make(
            configuration: configuration,
            token: { credentials.token }
        )

        let response = try await client.whoamiApiAuthUserGet(.init())
        guard case .ok(let ok) = response else {
            Issue.record("expected 200, got \(response)")
            return
        }
        #expect(!(try ok.body.json.subject).isEmpty)
    }
}
