import Foundation
import MemosAPI

/// Why a stored credential could not be confirmed at launch, as a value rather than as a sentence.
///
/// `restore()` asks the server about the token before the app may show anything, and what it
/// catches when that request does not arrive is the generated client's `ClientError`. Its
/// `description` spells out the operation, the `operationInput`, the request and the
/// `requestBody`; its `localizedDescription` is the "Client encountered an error invoking …"
/// line that reached a launch screen as the whole of what the app had to say. Neither may be
/// displayed, stored or logged (the rule at `NativeLoginTransportFailure`), so the failure is
/// classified before it becomes a sentence and only the classification leaves this type.
///
/// `NativeLoginError` is deliberately not reused. It answers with a single `message`, and a launch
/// failure needs the sentence and the one action apart: exactly one of these can be fixed from
/// inside Settings, and a screen must not have to match on wording to find out which one it is
/// holding.
public enum SessionRestoreFailure: Error, Sendable, Equatable {
    /// The Local Network permission denied the connect. The one failure Settings can fix, and not
    /// an edge case on this deployment: the server is a host on the home LAN.
    case localNetworkDenied
    /// The phone could not reach the network at all.
    case offline(host: String)
    /// The request did not arrive, named by the host and by the NSError domain and code only.
    case unreachable(host: String, detail: String)
    /// The server ANSWERED and said no. Its own sentence is the better one, and it is built from a
    /// status code rather than from anything the request carried.
    case server(APIError)

    /// The transport classification, given the server this launch was pointed at.
    ///
    /// The host is passed in rather than read from the error because the error is not allowed to
    /// be read: it is the same `ClientError` whose description this whole type exists to keep off
    /// the screen.
    public init(_ failure: NativeLoginTransportFailure, host: String) {
        switch failure {
        case .localNetworkDenied: self = .localNetworkDenied
        case .offline: self = .offline(host: host)
        case .other(let detail): self = .unreachable(host: host, detail: detail)
        }
    }

    /// The same three sentences, over the classification a STORE's failure produces.
    ///
    /// Two vocabularies, one set of sentences: the sign-in lane classifies into
    /// `NativeLoginTransportFailure` and a store's request into `ServerReachability.Reason`, and
    /// what the person reads must not depend on which lane noticed. Everything that is neither the
    /// Local Network denial nor a phone with no network is the same "can't reach it" sentence with
    /// a short detail — the status for a gateway, the domain and code otherwise, and never the
    /// error's own text.
    public init(_ reason: ServerReachability.Reason, host: String) {
        switch reason {
        case .localNetworkDenied: self = .localNetworkDenied
        case .offline: self = .offline(host: host)
        case .gateway(let status):
            self = .unreachable(host: host, detail: "HTTP \(status)")
        case .other(let detail):
            self = .unreachable(host: host, detail: detail)
        case .timedOut:
            self = .unreachable(host: host, detail: "timed out")
        case .cannotConnect:
            self = .unreachable(host: host, detail: "no connection to the host")
        case .connectionLost:
            self = .unreachable(host: host, detail: "the connection was lost")
        case .dnsFailure:
            self = .unreachable(host: host, detail: "its name would not resolve")
        }
    }
}

extension SessionRestoreFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .localNetworkDenied:
            "This phone is not letting the app reach your home network."
        case .offline(let host):
            "Can't reach \(host). This phone looks offline."
        case .unreachable(let host, let detail):
            "Can't reach \(host) (\(detail))."
        case .server(let error):
            error.errorDescription
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .localNetworkDenied:
            "Allow Local Network for memosng in Settings, then tap Try again."
        case .offline, .unreachable:
            "Join your home wifi (or turn on NetBird) and tap Try again."
        case .server:
            // A server that answered is not something the person can do anything about beyond the
            // retry the screen already offers, and inventing an instruction for it would be a
            // wrong answer stated confidently.
            nil
        }
    }

    /// The two halves as the one string a state can carry.
    ///
    /// `SessionState.unreachable` holds a sentence, and the screen behind it renders that sentence
    /// and nothing else, so what happened and what to do about it have to travel together. They
    /// are still kept apart above, because that is the pair `LocalizedError` defines and the pair
    /// a future banner may want to weight differently.
    public var message: String {
        [errorDescription, recoverySuggestion].compactMap { $0 }.joined(separator: " ")
    }
}
