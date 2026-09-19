import Foundation
import MemosAPI
import OpenAPIRuntime

/// Whether a request reached the server, decided from the error and only from the error.
///
/// The failure this exists for leaves the phone with a perfectly good network path: the household's
/// VPN tunnel drops, the routing table still says satisfied, and every request to the server dies
/// on the way. So reachability cannot be read off a path monitor — it is a property of request
/// OUTCOMES, and this is where they are read.
///
/// It classifies ERRORS, and only errors. A successful response is not an input here and is never
/// fabricated into one: `.reached` is what an ANSWER that is not a refusal classifies to — a 500, a
/// 404, a body that would not decode — and the success half of the story is reported where a
/// success actually exists, at a store's list-apply point.
///
/// Nothing it returns may carry the error's own text. The generated client's `ClientError`
/// description spells out `operationInput` and `requestBody`, which on the sign-in lane are a
/// handoff code and a PKCE verifier; that text may not be displayed, stored or logged (the rule at
/// `NativeLoginTransportFailure`), so `other` carries the NSError domain and code and nothing else.
public enum ServerReachability: Sendable, Equatable {
    /// The request did not reach the server.
    case unreachable(Reason)
    /// The server refused the credential. An auth outcome, and never this banner.
    case refused
    /// The server answered — whatever it said.
    case reached

    /// Why a request did not reach the server, in the categories the app has something to say
    /// about.
    public enum Reason: Sendable, Equatable {
        case timedOut
        case cannotConnect
        case connectionLost
        /// `cannotFindHost` and `dnsLookupFailed` both: one case, because the app has the same
        /// thing to say about either.
        case dnsFailure
        case offline
        /// The Local Network permission denied the connect — ENETDOWN on a -1009.
        case localNetworkDenied
        /// A gateway answered for a server that did not. 502 and 504 only.
        case gateway(status: Int)
        /// Anything else, named by NSError domain and code only.
        case other(String)
    }

    /// How far down an error chain to look. A wrapper around a wrapper is ordinary; sixteen is not,
    /// and a cycle must not become a hang. (Same bound, same reason, as the two walks beside it.)
    private static let maximumDepth = 16
    /// Where CFNetwork files the POSIX errno of a failed connect on a URL error.
    private static let streamErrorCodeKey = "_kCFStreamErrorCodeKey"
    /// ENETDOWN, "network is down" — what a denied Local Network connect fails with.
    private static let networkIsDown = 50
    /// The statuses that mean the proxy answered for a server that did not.
    private static let gatewayStatuses = [502, 504]

    public static func classify(_ error: any Error) -> ServerReachability {
        // First, because a refusal is neither an `APIError` nor a carrier of one in the shape the
        // installed client throws, and read any later it would look like an opaque failure.
        if StoreFailure.refusal(error) != nil { return .refused }
        if let api = apiError(in: error) {
            guard case .server(let status) = api, gatewayStatuses.contains(status) else {
                return .reached
            }
            return .unreachable(.gateway(status: status))
        }
        let chain = chain(from: error)
        // The URL loading system's own domain, rather than everything that is not an `APIError`:
        // that wider test also catches a body this app could not decode, and a decoding defect is
        // an answer the server gave.
        guard let index = chain.firstIndex(where: { $0.domain == NSURLErrorDomain }) else {
            return .reached
        }
        return .unreachable(reason(of: chain[index], rest: chain[index...]))
    }

    private static func reason(
        of urlError: NSError,
        rest: ArraySlice<NSError>
    ) -> Reason {
        switch URLError.Code(rawValue: urlError.code) {
        case .timedOut: .timedOut
        case .cannotConnectToHost: .cannotConnect
        case .networkConnectionLost: .connectionLost
        case .cannotFindHost, .dnsLookupFailed: .dnsFailure
        case .notConnectedToInternet:
            // The errno is read from the -1009 itself or from what it wraps: CFNetwork sometimes
            // files it one level down. A satisfied path hint is deliberately not read at all — it
            // says where the routing table stood, not what the socket did, and a dropped tunnel
            // leaves it satisfied.
            if rest.contains(where: { streamErrorCode(of: $0) == networkIsDown }) {
                .localNetworkDenied
            } else {
                .offline
            }
        default: .other("\(urlError.domain) \(urlError.code)")
        }
    }

    /// The `APIError` anywhere in an error's chain, or nil.
    ///
    /// `APIErrorCarrying` as well as the type itself: the failures the lanes outside the generated
    /// client meet are wrappers, and one read as an opaque error loses the status it was about.
    private static func apiError(in error: any Error) -> APIError? {
        var current: (any Error)? = error
        for _ in 0..<maximumDepth {
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

    /// The error and everything it wraps, outermost first.
    ///
    /// `ClientError` is stepped THROUGH rather than judged: it is the generated client's envelope,
    /// it is the same for every failure, and what it carries besides the cause is the request body.
    private static func chain(from error: any Error) -> [NSError] {
        var errors: [NSError] = []
        var current: (any Error)? = error
        for _ in 0..<maximumDepth {
            guard let error = current else { break }
            if let client = error as? ClientError {
                current = client.underlyingError
                continue
            }
            let next = error as NSError
            errors.append(next)
            current = next.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }

    private static func streamErrorCode(of error: NSError) -> Int? {
        let raw = error.userInfo[streamErrorCodeKey]
        return (raw as? NSNumber)?.intValue ?? raw as? Int
    }
}
