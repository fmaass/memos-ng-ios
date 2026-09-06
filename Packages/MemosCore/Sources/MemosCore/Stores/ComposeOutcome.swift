import Foundation
import MemosAPI

/// Why a compose did not go through.
///
/// It replaces a `Bool` and a sentence dropped into the store's global error line. The Bool could
/// only say "no", so every failure looked the same to the sheet that had to react to one: an
/// unreachable server, an expired sign-in and a refusal by the server all produced the same red
/// line and the same advice. The categories here are the ones a person can act on differently —
/// wait, sign in, make room, or change what they wrote.
public enum ComposeFailure: Sendable, Equatable {
    /// The server was not reached, or its answer never came back.
    ///
    /// `sent` is the part that matters and the part a Bool cannot carry. False is "this never left
    /// the device" — nothing has changed, and the words are safe where they are. True is a request
    /// that WENT and whose answer was lost: the edit may well have been applied, so the honest
    /// sentence is that it could not be confirmed. Saying "nothing was changed" there is a claim
    /// this app is in no position to make, and the retry is safe either way because it goes out
    /// under the same edit key (`TimelineStore.editKey(for:)`), which the server answers as a
    /// replay rather than applying twice.
    case transport(sent: Bool)
    /// Nobody is signed in for this any more — the session ended, or the credential was replaced
    /// while the sheet stood open.
    case authorization
    /// The device could not keep the capture: no room, or a file that could not be read or copied.
    case storage
    /// The server answered, and its answer was no.
    case rejection
}

/// What a compose attempt did.
public enum ComposeOutcome: Sendable, Equatable {
    case saved
    case failed(ComposeFailure)

    public var isSaved: Bool { self == .saved }

    public var failure: ComposeFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

extension ComposeFailure {
    /// What a thrown error means for a compose.
    ///
    /// `sent` is the caller's knowledge, not the error's: only the code that issued the request
    /// knows whether it had gone out by the time this came back, and no error carries that fact.
    public static func classify(_ error: any Error, sent: Bool) -> ComposeFailure {
        if StoreFailure.isSuperseded(error) { return .authorization }
        if StoreFailure.transportFailure(error) != nil { return .transport(sent: sent) }
        if StoreFailure.isCancellation(error) { return .transport(sent: sent) }
        if let api = error as? APIError {
            return api == .unauthorized ? .authorization : .rejection
        }
        let bridged = error as NSError
        if bridged.domain == NSCocoaErrorDomain, storageCodes.contains(bridged.code) {
            return .storage
        }
        return .rejection
    }

    /// The Cocoa codes a file that could not be read, written or made room for comes back as.
    private static let storageCodes: Set<Int> = [
        NSFileReadNoSuchFileError, NSFileReadNoPermissionError, NSFileReadUnknownError,
        NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError,
        NSFileWriteUnknownError,
    ]
}
