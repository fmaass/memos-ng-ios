import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Builds the generated client for a server and a credential.
///
/// It returns `any APIProtocol` on purpose: `APIProtocol` is the generated protocol every
/// operation is declared on, so it is also the seam tests substitute. Handing callers the concrete
/// `Client` would make the stores untestable without a live server.
public enum APIClientFactory {
    /// Everything about the client except where it points and what it carries. Tests build their
    /// client through the transport overload below so that they exercise THIS configuration —
    /// a test that quietly used the default date handling would pass while production could not
    /// decode a single memo.
    public static var runtimeConfiguration: Configuration {
        Configuration(dateTranscoder: RFC3339DateTranscoder())
    }

    public static func make(
        configuration: ServerConfiguration,
        token: @escaping @Sendable () async -> String?,
        urlSession: URLSession = .shared
    ) -> any APIProtocol {
        make(
            configuration: configuration,
            token: token,
            transport: URLSessionTransport(configuration: .init(session: urlSession))
        )
    }

    /// The seam tests substitute: a real generated client over a transport that answers from a
    /// script.
    public static func make(
        configuration: ServerConfiguration,
        token: @escaping @Sendable () async -> String?,
        transport: any ClientTransport
    ) -> any APIProtocol {
        Client(
            serverURL: configuration.baseURL,
            configuration: runtimeConfiguration,
            transport: transport,
            middlewares: [BearerAuthMiddleware(token: token)]
        )
    }

    /// The session's own client: it presents whatever the credential holds at the moment each
    /// request goes out, so a renewal reaches every client already built — and a refusal of a
    /// token the renewal replaced is fenced off from the rule that ends sessions
    /// (`PresentedCredential`).
    public static func make(
        configuration: ServerConfiguration,
        credential: PresentedCredential,
        urlSession: URLSession = .shared
    ) -> any APIProtocol {
        make(
            configuration: configuration,
            credential: credential,
            transport: URLSessionTransport(configuration: .init(session: urlSession))
        )
    }

    public static func make(
        configuration: ServerConfiguration,
        credential: PresentedCredential,
        transport: any ClientTransport
    ) -> any APIProtocol {
        Client(
            serverURL: configuration.baseURL,
            configuration: runtimeConfiguration,
            transport: transport,
            middlewares: [BearerAuthMiddleware(credential: credential)]
        )
    }

    /// The management screen's own client: it presents the step-up grant, and it is built with
    /// `GrantAuthMiddleware` ALONE.
    ///
    /// That is the guarantee rather than an implementation detail. This client holds no reference
    /// to the session's credential, so there is no branch — no fallback, no "if the grant is
    /// missing" — by which the device's personal access token could be attached to a `/api/pats`
    /// request. A device token manages nothing but itself (ADR-0015), and the way to keep that
    /// true from this side is for the client that reaches token management to have never been
    /// able to see one.
    ///
    /// It is also the client that BUYS the grant, made before there is one to present: the mint
    /// request is anonymous by construction, exactly as the sign-in exchange is.
    public static func make(
        configuration: ServerConfiguration,
        grant: ManagementGrant,
        urlSession: URLSession = .shared
    ) -> any APIProtocol {
        make(
            configuration: configuration,
            grant: grant,
            transport: URLSessionTransport(configuration: .init(session: urlSession))
        )
    }

    public static func make(
        configuration: ServerConfiguration,
        grant: ManagementGrant,
        transport: any ClientTransport
    ) -> any APIProtocol {
        Client(
            serverURL: configuration.baseURL,
            configuration: runtimeConfiguration,
            transport: transport,
            middlewares: [GrantAuthMiddleware(grant: grant)]
        )
    }
}
