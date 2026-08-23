import Foundation

/// The single error type crossing this package's boundary.
///
/// Callers act on `unauthorized` (the session is over — there is no refresh token to fall back
/// on) and can report the rest; leaking `URLError`, `DecodingError` and the generated
/// `ClientError` upwards would make every caller re-classify the same failures differently.
public enum APIError: Error, Sendable, Equatable {
    /// The credential was missing, wrong or revoked. Drives sign-out; never retried silently.
    case unauthorized
    case notFound
    case server(status: Int)
    case transport(description: String)
    case decoding(description: String)
    case unexpected(description: String)

    /// Classifies a status code the generated client reported as undocumented.
    public static func fromStatus(_ status: Int) -> APIError {
        switch status {
        case 401, 403: .unauthorized
        case 404: .notFound
        default: .server(status: status)
        }
    }
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Your access token was rejected. Sign in again."
        case .notFound: "That item no longer exists."
        case .server(let status): "The server returned an error (HTTP \(status))."
        case .transport(let description): "The server could not be reached: \(description)"
        case .decoding(let description): "The server sent an unexpected response: \(description)"
        case .unexpected(let description): description
        }
    }
}
