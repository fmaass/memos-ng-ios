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

    /// How long a request may go without a single byte before it is given up on.
    ///
    /// Measured rather than preferred: against a destination that is routed and answers nothing, a
    /// request on the framework's defaults took the full 60 seconds to fail. This is the idle
    /// bound between bytes, and it is the only one set here. No TOTAL deadline stands beside it —
    /// the same call the media session makes about its own long transfer, for the mirror-image
    /// reason: this client carries the binary chunks of a foreground edit's upload as well as
    /// small JSON, and a deadline on the whole transfer would kill an upload that is still making
    /// progress on a slow link, failing the edit before its patch is ever sent.
    public static let requestTimeout: TimeInterval = 15

    /// The session every client built here fetches through, in place of `URLSession.shared`.
    ///
    /// `.shared` cannot be given this bound: a session COPIES its configuration when it is made
    /// and never reads it again, so reconfiguring the shared one afterwards changes nothing, and
    /// the only way to put a limit on a request this app sends is to own the session it goes out
    /// on. Owning one also keeps the limit off every other user of the shared session.
    public static var urlSession: URLSession { bounded.session }

    /// `@unchecked Sendable` for the reason `MediaSession` is one: the single stored property is a
    /// `let`, and `URLSession` is documented as safe to use from several threads at once.
    private final class BoundedSession: @unchecked Sendable {
        let session: URLSession

        init() {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = APIClientFactory.requestTimeout
            session = URLSession(configuration: configuration)
        }
    }

    private static let bounded = BoundedSession()

    public static func make(
        configuration: ServerConfiguration,
        token: @escaping @Sendable () async -> String?,
        urlSession: URLSession = APIClientFactory.urlSession
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
        urlSession: URLSession = APIClientFactory.urlSession
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
        licence: GrantSendLicence,
        urlSession: URLSession = APIClientFactory.urlSession
    ) -> any APIProtocol {
        make(
            configuration: configuration,
            grant: grant,
            licence: licence,
            transport: URLSessionTransport(configuration: .init(session: urlSession))
        )
    }

    public static func make(
        configuration: ServerConfiguration,
        grant: ManagementGrant,
        licence: GrantSendLicence,
        transport: any ClientTransport
    ) -> any APIProtocol {
        Client(
            serverURL: configuration.baseURL,
            configuration: runtimeConfiguration,
            transport: transport,
            middlewares: [GrantAuthMiddleware(grant: grant, licence: licence)]
        )
    }
}
