import Foundation
import MemosAPI

/// Everything that can go wrong between "sign in" and a token in the keychain.
///
/// One typed enum rather than whatever each layer happened to throw: the flow spans a browser
/// sheet, a redirect and an HTTP call, and the screen showing the result has to tell a cancel
/// apart from a failure — a cancel is not an error to report, and everything else is.
public enum NativeLoginError: Error, Sendable, Equatable {
    /// The person closed the sheet. Not a failure, and never reported as one.
    case cancelled
    /// The authentication session could not be put on screen at all.
    case presentationFailed(String)
    /// The identity provider refused, carrying the reason it redirected back with.
    case refused(reason: String)
    /// The callback arrived with neither a code nor a reason.
    case malformedCallback
    /// The server refused to trade the handoff code for a token. Terminal, all four of them.
    case exchangeRejected(NativeExchangeFailure)
    /// The address typed into the sign-in field cannot become an https base URL.
    case invalidServer
    /// The login could not even be started: a device name or challenge the server would reject.
    case unusableRequest
    /// Anything the API layer classified.
    case api(APIError)

    /// What to show. `cancelled` deliberately has nothing to say.
    public var message: String? {
        switch self {
        case .cancelled: nil
        case .presentationFailed(let detail): "The sign-in window could not open: \(detail)"
        case .refused(let reason): "The sign-in was refused (\(reason))."
        case .malformedCallback: "The sign-in came back incomplete. Please try again."
        case .exchangeRejected(let failure): failure.message
        case .invalidServer: "That does not look like an https server address."
        case .unusableRequest: "This device's name could not be used to sign in."
        case .api(let error): error.errorDescription
        }
    }
}

/// Puts the web login on screen and hands back the URL it finished on.
///
/// The protocol lives here and its implementation lives in the UI layer: `MemosCore` also builds
/// for macOS (that is how the gate proves it compiles warning-free) and the authentication session
/// is a UI object. Splitting it this way also makes every branch of the flow testable — a stub
/// presenter can cancel, fail to present, or hand back any callback URL at all.
public protocol NativeLoginPresenter: Sendable {
    /// - Returns: the callback URL the session landed on.
    /// - Throws: `NativeLoginError.cancelled` or `.presentationFailed`.
    @MainActor
    func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String
    ) async throws -> URL
}
