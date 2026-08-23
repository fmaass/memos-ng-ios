import Foundation
import MemosAPI

/// Where the app is with respect to a credential.
public enum SessionState: Sendable, Equatable {
    case signedOut
    case signingIn
    case signedIn(User)

    public var user: User? {
        if case .signedIn(let user) = self { return user }
        return nil
    }
}

/// The session: one credential, one server, and the rule that a 401 ends it.
///
/// There is no refresh lifecycle to fall back on (the personal access token IS the credential)
/// so an unauthorised response is terminal by design, and a silent retry would only turn a
/// revoked token into a spinner.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var state: SessionState = .signedOut
    public private(set) var lastError: String?
    public private(set) var configuration: ServerConfiguration?

    private let credentials: any CredentialStore
    private let makeClient:
        @Sendable (ServerConfiguration, @escaping @Sendable () async -> String?) -> any APIProtocol
    private var client: (any APIProtocol)?

    public static let tokenAccount = "device-token"
    public static let serverAccount = "server-url"

    public init(
        credentials: any CredentialStore = Keychain(service: "live.discomarder.memosng"),
        makeClient:
            @escaping @Sendable (
                ServerConfiguration, @escaping @Sendable () async -> String?
            ) -> any APIProtocol = { configuration, token in
                APIClientFactory.make(configuration: configuration, token: token)
            }
    ) {
        self.credentials = credentials
        self.makeClient = makeClient
    }

    /// The client every feature talks through, or `nil` while signed out.
    public var api: (any APIProtocol)? { client }

    public var serverBaseURL: URL? { configuration?.baseURL }

    /// Validates a pasted token against `GET /api/auth/user` before storing it: a credential that
    /// is only checked at first use fails later, in the middle of something else.
    public func signIn(serverAddress: String, token candidate: String) async {
        guard let configuration = ServerConfiguration(serverAddress: serverAddress) else {
            lastError = "That does not look like an https server address."
            return
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Paste the access token from the memos web app."
            return
        }

        state = .signingIn
        lastError = nil
        let client = makeClient(configuration) { trimmed }
        do {
            let user = try await Self.whoami(client)
            self.configuration = configuration
            self.client = client
            state = .signedIn(user)
            try? credentials.set(trimmed, for: Self.tokenAccount)
            try? credentials.set(configuration.baseURL.absoluteString, for: Self.serverAccount)
        } catch {
            state = .signedOut
            self.client = nil
            lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Restores a stored credential at launch and re-validates it, so a token revoked while the
    /// app was closed shows a sign-in screen rather than an empty timeline.
    public func restore() async {
        guard let storedToken = (try? credentials.string(for: Self.tokenAccount)) ?? nil,
            let storedAddress = (try? credentials.string(for: Self.serverAccount)) ?? nil
        else { return }
        await signIn(serverAddress: storedAddress, token: storedToken)
        // A credential the server no longer accepts is not worth keeping: leaving it would retry a
        // revoked token at every launch and show the same failure every time.
        if state.user == nil {
            try? credentials.remove(Self.tokenAccount)
            try? credentials.remove(Self.serverAccount)
        }
    }

    /// Revokes the presenting token server-side, then wipes it locally EVEN IF that call failed —
    /// a device that thinks it is signed out while still holding a live token is the worse state.
    public func signOut() async {
        if let client {
            _ = try? await client.nativeLogoutApiAuthNativeLogoutPost(.init())
        }
        try? credentials.remove(Self.tokenAccount)
        try? credentials.remove(Self.serverAccount)
        client = nil
        configuration = nil
        state = .signedOut
    }

    /// The 401 rule, in one place: any feature that sees `.unauthorized` calls this.
    public func handle(_ error: APIError) async {
        if error == .unauthorized { await signOut() }
    }

    static func whoami(_ client: any APIProtocol) async throws -> User {
        let response = try await client.whoamiApiAuthUserGet(.init())
        switch response {
        case .ok(let ok):
            MemosLog.session.info("GET /api/auth/user -> 200")
            return User(try ok.body.json)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }
}
