import Foundation
import MemosCore

/// What the compose sheet says when a save did not go through, and what it does to the tiles.
///
/// One sentence per category, and each one is answerable: wait, sign in, make room, or change what
/// you wrote. The sentence a raw error would have produced is deliberately not shown — an
/// `NSURLErrorDomain -1009` on a sheet is not information, it is an apology in a foreign language.
nonisolated public enum ComposeFailurePresentation {
    public static func sentence(for failure: ComposeFailure) -> String {
        switch failure {
        case .transport(let sent):
            return sent
                // The one sentence this app may not say here is "nothing was changed". The request
                // went out; only its answer was lost, so the edit may well have been applied. The
                // retry is safe either way — it goes under the same edit key, which the server
                // answers as a replay rather than applying twice.
                ? "This could not be confirmed: the answer never came back."
                    + " Try again — the same save is repeated, never applied twice."
                : "The server could not be reached, so nothing has been changed yet."
                    + " The memo is still here — try again."
        case .authorization:
            return "This device is not signed in any more. Sign in and try again."
        case .storage:
            return "There was no room on this device to keep this."
        case .rejection:
            return "The server would not accept this. Nothing was changed."
        }
    }

    /// What the failure means for the tiles of the files that were going up with it.
    ///
    /// Only a transport failure is the FILES' business — the file is fine and the network is not,
    /// which is exactly what "needs connection" says. A refusal or an expired session is about the
    /// memo, and marking the photographs for it would send somebody looking for a network that
    /// would not have helped.
    public static func tileCategory(for failure: ComposeFailure) -> ComposeLoadFailure? {
        switch failure {
        case .transport: return .transport
        case .storage: return .storage
        case .authorization, .rejection: return nil
        }
    }
}
