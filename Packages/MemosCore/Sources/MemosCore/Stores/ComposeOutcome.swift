import Foundation
import MemosAPI
import MemosOutbox
import OpenAPIRuntime

/// Why a compose did not go through.
///
/// A compose answers with this rather than with a `Bool`, and the sheet acts on this alone — it
/// never reads the store's global error line. That line is the LIST's, and a compose does reach
/// it: the store clears it when a save's request is answered well, and hands a request that failed
/// to the same reporter its reads use (`TimelineStore.report`). A compose refused before anything
/// was sent leaves that line as it was. The Bool could only say "no", so every failure looked the
/// same to the sheet that had to react to one: an unreachable server, an expired sign-in and a
/// refusal by the server all produced the same red line and the same advice. The categories here
/// are the ones a person can act on differently — wait, sign in, make room, or change what they
/// wrote.
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
    /// The server took the request and broke on it, so what it did with it is unknown.
    ///
    /// Separate from `rejection` because the two are opposite facts about the same memo: a refusal
    /// is the server declining to act, and this is the server acting and then failing to say what
    /// it did. It commits an edit before it builds the answer, so the words may well be on the
    /// memo. The retry is safe for the reason `transport(sent: true)`'s is — the same edit key,
    /// which the server replays rather than applying twice.
    case serverFailure
    /// The queue refused to put this capture back where it came from: nothing was sent and
    /// nothing changed. Each reason is answerable differently, so the refusal is carried whole.
    case captureUnchanged(ResubmitRefusal)
    /// "Default" was chosen and the account's own default is not known, so there is no value a
    /// memo could carry that means it. Nothing was asked of the queue.
    case defaultVisibilityUnknown
}

/// What a compose attempt did.
public enum ComposeOutcome: Sendable, Equatable {
    case saved
    case failed(ComposeFailure)
    /// Nothing was sent: the visibility change this carried was a narrowing when it was proposed
    /// and had become a widening by the time its memo's line reached it (MEMNG-981). It is neither
    /// a failure nor a refusal — the caller asks this question exactly as it asks any widening,
    /// and sends only its `confirmed()` change; a dismissal sends nothing.
    case ask(VisibilityChange.Question)

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
            default:
                return switch serverAnswer(to: api) {
                case .refused: .rejection
                case .unconfirmed: .serverFailure
                }
            }
        }
        // The same fact arriving as the raw decoding failure, which is what a 2xx body the client
        // cannot read throws before anything wraps it.
        if isDecodingFailure(error) { return .transport(sent: sent) }
        if let storage = storageFailure(in: error) { return storage }
        return .rejection
    }

    /// What an answer the server itself gave says about whether it acted on the request.
    ///
    /// The ONE reading of a status, so that what somebody is told and what the row is left knowing
    /// cannot be edited apart: both consult this, neither decides for itself. A status inside the
    /// 4xx class is the server declining to act, and the memo it holds is as it was; anything else
    /// it answered with is the server having taken the request and broken on it, which is an open
    /// question because it commits an edit before it builds the answer.
    ///
    /// A 502 or a 504 reaches this in the row reading and comes back an open question, which is
    /// what it has always been there. The compose reading never gets this far with one: those two
    /// are the proxy speaking for a server that is not there, and it takes them earlier as the
    /// unreachable server they describe (`StoreFailure.transportFailure`).
    static func serverAnswer(to api: APIError) -> ServerAnswer {
        switch api {
        case .unauthorized, .forbidden, .notFound: .refused
        case .server(let status) where (400..<500).contains(status): .refused
        default: .unconfirmed
        }
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
/// — with the second copy free to drift. It sits beside `ComposeFailure` because both readings are
/// of the same answer: what the person is told and what the row is left knowing must not be able to
/// disagree about what the server did.
enum ServerAnswer: Sendable, Equatable {
    /// The server considered the request and declined it. Nothing it holds moved.
    case refused
    /// The server took the request and did not say what became of it.
    case unconfirmed
}

enum MemoMutationEffect: Sendable, Equatable {
    /// Nothing was sent, or the server refused the request in a way that leaves the memo as it was:
    /// a read already on its way knows that memo as well as this mutation does.
    case changedNothing
    /// The request left and no answer vouches for what became of it, so only a read issued after
    /// this moment can say what the memo is.
    case outcomeUnknown

    static func of(_ error: any Error) -> MemoMutationEffect {
        // Asked through the store layer's one reading of the chain, because a credential the device
        // installed does not meet this as an `APIError` at all: the middleware throws the typed
        // value, which is neither an `APIError` nor a carrier of one, and a switch on status alone
        // reads every refused mutation as an open question. It is a statement about what the server
        // holds — it did not act on the request — so WHICH credential earned it does not enter into
        // it; that question belongs to the session and is asked there.
        if StoreFailure.refusal(error) != nil { return .changedNothing }
        // An error carrying no answer of the server's — a decode, a phone with no network — is an
        // open question by the same rule, and there is no status to ask about.
        guard let api = ComposeFailure.apiError(in: error) else { return .outcomeUnknown }
        return switch ComposeFailure.serverAnswer(to: api) {
        case .refused: .changedNothing
        case .unconfirmed: .outcomeUnknown
        }
    }
}
