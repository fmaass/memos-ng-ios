import Foundation
import OpenAPIRuntime

/// What a failed exchange turned out to be, decided from the error alone.
///
/// It exists because exactly one transport failure may be retried with the same handoff code, and
/// telling it apart from every other one is a wire fact, not a judgement. iOS Local Network privacy
/// denies the app process's FIRST connection to a private-range host — the one that raises the
/// permission prompt — by failing the connect(2) with ENETDOWN, which CFNetwork reports as
/// `_kCFStreamErrorCodeKey = 50` under an `NSURLErrorNotConnectedToInternet` (-1009). A connect
/// that never completed transmitted nothing, so the one-shot code the request carried is provably
/// unconsumed and may be sent again.
///
/// A -1009 WITHOUT that stream code is a different animal: the phone may have been offline, or the
/// request may have gone out and died on the way back. It proves nothing about consumption, so it
/// is `offline` and it is never retried. A satisfied `_NSURLErrorNWPathKey` does not qualify
/// either: a satisfied path says where the routing table stood, not what the socket did.
///
/// The classification is the ONLY thing that leaves this type. The error the generated client
/// throws for a failed exchange is a `ClientError`, and its description spells out the request it
/// was making: `operationInput` and `requestBody` are the handoff code and the PKCE verifier. That
/// text may not be logged, displayed or stored, so nothing here produces it: `other` carries the
/// NSError domain and code and nothing else.
public enum NativeLoginTransportFailure: Sendable, Equatable {
    /// The Local Network permission denied the connect. The one retryable failure.
    case localNetworkDenied
    /// The phone could not reach the network, and nothing here can prove what was sent.
    case offline
    /// Anything else, named by NSError domain and code only.
    case other(String)

    /// Where CFNetwork files the POSIX errno of a failed connect on a URL error.
    private static let streamErrorCodeKey = "_kCFStreamErrorCodeKey"
    /// ENETDOWN, "network is down" — what a denied Local Network connect fails with.
    private static let networkIsDown = 50
    /// How far down an error chain to look. A wrapper around a wrapper is ordinary; sixteen is
    /// not, and a cycle must not become a hang.
    private static let maximumDepth = 16

    public static func classify(_ error: any Error) -> NativeLoginTransportFailure {
        let chain = chain(from: error)
        guard let index = chain.firstIndex(where: { $0.domain == NSURLErrorDomain }) else {
            return .other(descriptor(chain.first))
        }
        let urlError = chain[index]
        guard urlError.code == URLError.Code.notConnectedToInternet.rawValue else {
            return .other(descriptor(urlError))
        }
        // The errno is read from the -1009 itself or from what it wraps: CFNetwork sometimes files
        // it one level down. Nowhere else — a stream code found beside a different URL error is
        // not this failure.
        let denied = chain[index...].contains { streamErrorCode(of: $0) == networkIsDown }
        return denied ? .localNetworkDenied : .offline
    }

    /// The only text about a failed exchange that may be written down: what it was classified as,
    /// and the domain and code it was classified from.
    public static func diagnostic(for error: any Error) -> String {
        let chain = chain(from: error)
        let named = chain.first { $0.domain == NSURLErrorDomain } ?? chain.first
        return "\(classify(error).label) (\(descriptor(named)))"
    }

    var label: String {
        switch self {
        case .localNetworkDenied: "local-network-denied"
        case .offline: "offline"
        case .other: "other"
        }
    }

    /// The error and everything it wraps, outermost first.
    ///
    /// `ClientError` is stepped THROUGH rather than reported: it is the generated client's
    /// envelope, it is the same for every failure, and what it carries besides the cause is the
    /// request body.
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

    private static func descriptor(_ error: NSError?) -> String {
        guard let error else { return "unknown error" }
        return "\(error.domain) \(error.code)"
    }
}
