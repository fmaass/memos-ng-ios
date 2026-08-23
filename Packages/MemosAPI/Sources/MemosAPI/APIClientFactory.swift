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
}
