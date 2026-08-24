import Foundation
import MemosAPI
import MemosOutbox

/// What the outbox is allowed to upload as, read from the same places the session reads.
///
/// The outbox deliberately knows nothing about sessions, keychains or servers, so the one thing it
/// does need — a base URL, who is signed in, and a bearer token — is handed to it through this.
/// The token is fetched per drain and never stored in a queued job: a credential written into a
/// queue file is a credential in the next backup.
public struct DeviceOutboxCredentials: OutboxCredentialsProviding {
    private let credentials: any CredentialStore
    private let owner: @Sendable () async -> String?

    /// - Parameter owner: the signed-in user's subject, or nil when nobody is signed in. It comes
    ///   from the session rather than from storage because the session is what knows whether the
    ///   stored token has been validated.
    public init(
        credentials: any CredentialStore = DeviceCredentials.keychain(),
        owner: @escaping @Sendable () async -> String?
    ) {
        self.credentials = credentials
        self.owner = owner
    }

    public func currentCredentials() async -> OutboxCredentials? {
        guard let subject = await owner(), !subject.isEmpty else { return nil }
        guard let token = (try? credentials.string(for: SessionStore.tokenAccount)) ?? nil,
            !token.isEmpty,
            let address = (try? credentials.string(for: SessionStore.serverAccount)) ?? nil,
            let configuration = ServerConfiguration(serverAddress: address)
        else { return nil }
        return OutboxCredentials(
            serverBaseURL: configuration.baseURL,
            ownerSubject: subject,
            token: token
        )
    }
}
