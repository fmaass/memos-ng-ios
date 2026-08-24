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

    /// Reads the credential through the one vault the app has, which is what serializes this
    /// read against a sign-out happening at the same moment.
    ///
    /// A storage failure ends in "nothing drains", because there is nothing else this layer can
    /// do with one — but it is logged rather than swallowed: a queue that refuses every capture
    /// while the keychain is answering with errors is exactly the silence that hid the last one.
    public func currentCredentials() async -> OutboxCredentials? {
        guard let subject = await owner(), !subject.isEmpty else { return nil }
        do {
            guard let token = try await credentials.string(for: SessionStore.tokenAccount),
                !token.isEmpty,
                let address = try await credentials.string(for: SessionStore.serverAccount),
                let configuration = ServerConfiguration(serverAddress: address)
            else { return nil }
            return OutboxCredentials(
                serverBaseURL: configuration.baseURL,
                ownerSubject: subject,
                token: token
            )
        } catch {
            let detail = String(describing: error)
            MemosLog.session.error(
                "the outbox could not read the device credential: \(detail, privacy: .public)"
            )
            return nil
        }
    }
}
