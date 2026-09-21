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
            // It names no server on purpose: a memo this app already knows was deleted is refused
            // here without anything being sent. And "nothing was changed" is not this case's to
            // say, because the one sentence has to serve that local refusal as well as a server's
            // own decline — so it sends somebody to look rather than telling them what they will
            // find.
            return "This save could not be confirmed. Check the memo before trying again."
        case .serverFailure:
            // Not the refusal's sentence: the server took this one and broke on it, and it commits
            // an edit before it builds its answer — so the words may be on the memo. The retry is
            // safe for the reason the lost answer's is, and saying so is the part somebody can act
            // on.
            return "The server failed on this save, so it is not known whether it went through."
                + " Try again — the same save is repeated, never applied twice."
        }
    }

    /// What the failure means for the tiles of the files that were going up with it.
    ///
    /// A transport failure that never left the device is the FILES' business — the file is fine
    /// and the network is not, which is exactly what "needs connection" says. A refusal or an
    /// expired session is about the memo, and marking the photographs for it would send somebody
    /// looking for a network that would not have helped.
    ///
    /// A request that WENT and lost its answer is not their business either, for a sharper reason
    /// than that: it says nothing about the files — they may be on the memo already — and what is
    /// attached is held where it is until that save is settled (`ComposeImports.mayHaveLanded`),
    /// so the
    /// "Try again" a marked tile carries is refused wherever it is pressed. The sentence across
    /// the sheet and the Save above it are what somebody acts on there; a control that cannot act
    /// is worse than no control.
    public static func tileCategory(for failure: ComposeFailure) -> ComposeLoadFailure? {
        switch failure {
        case .transport(let sent): return sent ? nil : .transport
        case .storage: return .storage
        case .authorization, .rejection, .serverFailure: return nil
        }
    }
}
