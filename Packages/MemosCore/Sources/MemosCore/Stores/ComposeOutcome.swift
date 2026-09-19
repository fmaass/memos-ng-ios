import Foundation
import MemosAPI
import OpenAPIRuntime

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
        if StoreFailure.refusal(error) != nil { return .authorization }
        if StoreFailure.transportFailure(error) != nil { return .transport(sent: sent) }
        if StoreFailure.isCancellation(error) { return .transport(sent: sent) }
        // Down the chain, not at the top of it: the generated client wraps what it is given, and an
        // `unauthorized` inside an envelope that is read as a plain refusal ends up telling somebody
        // the server said no to their words when it in fact refused their session.
        if let api = apiError(in: error) {
            switch api {
            case .unauthorized: return .authorization
            // An answer the client could not read is not an answer that the memo was refused. The
            // request went out and the server may well have applied it — see `.transport(sent:)`,
            // and the sentence that goes with it.
            case .decoding: return .transport(sent: sent)
            default: return .rejection
            }
        }
        // The same fact arriving as the raw decoding failure, which is what a 2xx body the client
        // cannot read throws before anything wraps it.
        if isDecodingFailure(error) { return .transport(sent: sent) }
        if let storage = storageFailure(in: error) { return storage }
        return .rejection
    }

    /// The `APIError` anywhere in an error's chain, or nil.
    ///
    /// `APIErrorCarrying` is checked as well as the type itself: the failures this app actually
    /// meets are wrappers — `MediaUploadError.refused(.unauthorized)` is what an upload against an
    /// ended session throws — and a wrapper read as an opaque error is a session failure reported
    /// as the server refusing somebody's words.
    fileprivate static func apiError(in error: any Error) -> APIError? {
        var current: (any Error)? = error
        for _ in 0..<16 {
            guard let error = current else { return nil }
            if let api = error as? APIError { return api }
            if let carried = (error as? any APIErrorCarrying)?.apiError { return carried }
            if let client = error as? ClientError {
                current = client.underlyingError
                continue
            }
            current = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// Whether a `DecodingError` is anywhere in the chain.
    private static func isDecodingFailure(_ error: any Error) -> Bool {
        var current: (any Error)? = error
        for _ in 0..<16 {
            guard let error = current else { return false }
            if error is DecodingError { return true }
            if let client = error as? ClientError {
                current = client.underlyingError
                continue
            }
            current = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// A file that could not be read, written or made room for, anywhere in the chain.
    private static func storageFailure(in error: any Error) -> ComposeFailure? {
        var current: NSError? = error as NSError
        for _ in 0..<16 {
            guard let error = current else { return nil }
            if error.domain == NSCocoaErrorDomain, storageCodes.contains(error.code) {
                return .storage
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// The Cocoa codes a file that could not be read, written or made room for comes back as.
    private static let storageCodes: Set<Int> = [
        NSFileReadNoSuchFileError, NSFileReadNoPermissionError, NSFileReadUnknownError,
        NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError,
        NSFileWriteUnknownError,
    ]
}

/// What a failed mutation says about the memo the server holds.
///
/// It is read here rather than at each lane for the reason a refusal is: the decision about a
/// status code is one decision, and a lane that re-derived it would be the same rule written twice
/// — with the second copy free to drift. It is also the only file in the store layer allowed to
/// name a refusal by its own name.
enum MemoMutationEffect: Sendable {
    /// Nothing was sent, or the server refused the request in a way that leaves the memo as it was:
    /// a read already on its way knows that memo as well as this mutation does.
    case changedNothing
    /// The request left and no answer vouches for what became of it, so only a read issued after
    /// this moment can say what the memo is.
    case outcomeUnknown

    static func of(_ error: any Error) -> MemoMutationEffect {
        switch ComposeFailure.apiError(in: error) {
        case .unauthorized, .forbidden, .notFound: .changedNothing
        case .server(let status) where (400..<500).contains(status): .changedNothing
        default: .outcomeUnknown
        }
    }
}
