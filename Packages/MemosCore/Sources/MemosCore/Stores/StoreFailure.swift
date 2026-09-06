import Foundation
import MemosAPI
import OpenAPIRuntime

/// What a store may say about a request that threw — and the one failure it must never speak of.
///
/// Every store in this layer FENCES its reads: a newer request supersedes an older one, and the
/// older one is cancelled where the transport can hear it. Cancelling a URLSession task is a
/// FAILURE as far as the stack is concerned — `NSURLErrorDomain -999`, wrapped by the generated
/// client's `ClientError` — so a store that reports whatever it catches reports the app's own
/// supersede back to the person who caused it. That is what MEMNG-180 was: tapping a tag while a
/// search was in flight raised "Client encountered an error invoking list_memos … -999 cancelled"
/// over a search that then worked perfectly.
///
/// The lineage fence does not catch it, and cannot. A fence compares the request's lineage with
/// the store's at the moment the answer lands, and the cancelling caller (`MemoSearch.typed`
/// cancels its `work` task, then waits out its debounce before touching the store) has not moved
/// the lineage yet — so the cancelled request is still, by that test, the current one. Cancellation
/// has to be recognised for what it is instead of inferred from who else has been past.
///
/// It is ONE place rather than one per store because the classification is the same everywhere and
/// a rule written five times is a rule that ends up written four ways.
public enum StoreFailure {
    /// How far down an error chain to look. A wrapper around a wrapper is ordinary; sixteen is
    /// not, and a cycle must not become a hang. (Same bound, same reason, as
    /// `NativeLoginTransportFailure`.)
    private static let maximumDepth = 16

    /// Whether this is the app's own cancellation coming back at it.
    ///
    /// Three shapes, because cancellation reaches a store by three routes: structured concurrency
    /// throwing `CancellationError` from a checked task, URLSession failing the transfer with
    /// `URLError.cancelled`, and either of those bridged to an `NSError` inside somebody's
    /// `userInfo`. `-999` under `NSURLErrorDomain` is the code in the owner's own evidence.
    public static func isCancellation(_ error: any Error) -> Bool {
        var current: (any Error)? = error
        for _ in 0..<maximumDepth {
            guard let error = current else { return false }
            if error is CancellationError { return true }
            // The generated client's envelope is stepped THROUGH, not judged: it is the same
            // wrapper for every failure and says nothing about which one this is.
            if let client = error as? ClientError {
                current = client.underlyingError
                continue
            }
            if let urlError = error as? URLError, urlError.code == .cancelled { return true }
            let bridged = error as NSError
            if bridged.domain == NSURLErrorDomain, bridged.code == NSURLErrorCancelled {
                return true
            }
            current = bridged.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Whether the middleware refused this on behalf of a credential the device has since
    /// replaced.
    ///
    /// It arrives wrapped in the generated client's envelope, exactly as a cancellation does, so
    /// it is looked for down the chain rather than at the top of it. A caller that treats it as a
    /// failure of the credential in hand ends a session that has just renewed.
    public static func isSuperseded(_ error: any Error) -> Bool {
        var current: (any Error)? = error
        for _ in 0..<maximumDepth {
            guard let error = current else { return false }
            if error is CredentialSuperseded { return true }
            if let client = error as? ClientError {
                current = client.underlyingError
                continue
            }
            current = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// The classification of a failure that never reached the server, or nil for one that did.
    ///
    /// This is the fork the whole "one surface for can't-reach-the-server" rule turns on. A
    /// transport-class failure goes to the session sink and never into a store's `lastError`; an
    /// answer the server gave — a 403, a 500 — is about the thing somebody just did and is
    /// reported where it always was. A cancellation is neither: it is this app's own supersede
    /// coming back at it.
    public static func transportFailure(_ error: any Error) -> NativeLoginTransportFailure? {
        guard !isCancellation(error), !isSuperseded(error) else { return nil }
        guard !(error is APIError), (error as? any APIErrorCarrying)?.apiError == nil else {
            return nil
        }
        guard NativeLoginTransportFailure.isTransportFailure(error) else { return nil }
        return NativeLoginTransportFailure.classify(error)
    }

    /// The failure a store should report, or nil for one it must swallow.
    ///
    /// Only cancellation is swallowed. Everything else — a 500, a decode, a phone with no network
    /// — is a thing that happened to a request somebody is waiting for, and a list that goes quiet
    /// instead of saying so is the worse failure by far.
    ///
    /// An error that WRAPS one of the API's own is unwrapped rather than described. The wrapping is
    /// how a lane outside the generated client (a media upload, an original download) says which
    /// step failed, and it must not cost the answer its identity: a 401 inside one is still the
    /// server saying this credential is dead, and `.unexpected("…")` around it is a 401 that never
    /// reaches the rule that ends the session.
    public static func reportable(_ error: any Error) -> APIError? {
        guard !isCancellation(error) else { return nil }
        if let error = error as? APIError { return error }
        if let carried = (error as? any APIErrorCarrying)?.apiError { return carried }
        return .unexpected(description: error.localizedDescription)
    }
}

/// An error from outside the generated client that is really one of the API's own underneath.
public protocol APIErrorCarrying {
    /// The API failure this stands for, or nil when it stands for something else entirely — a file
    /// that would not read, a download that would not save.
    var apiError: APIError? { get }
}
