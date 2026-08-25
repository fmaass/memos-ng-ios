import Foundation
import MemosCore
import OpenAPIRuntime
import Testing

/// What a failed exchange was, decided from the error alone.
///
/// The distinction pinned here is not cosmetic. `localNetworkDenied` is the ONE classification the
/// sign-in retries on, and it may be retried only because ENETDOWN raised at connect means the
/// socket was never established: nothing was transmitted, so the one-shot handoff code is provably
/// unconsumed. A -1009 without that stream code proves no such thing — the request may well have
/// reached the server — so it must never produce a second attempt with the same code.
@Suite("The exchange's transport failures")
struct NativeLoginTransportFailureTests {
    /// Stands in for the generated operation's Input, which is what the real `ClientError` carries
    /// in `operationInput`: the handoff code and the PKCE verifier, spelled out.
    private struct ExchangeInput: Sendable {
        let code = "handoff-123"
        let codeVerifier = "verifier-abcdefghijklmnop"
    }

    private struct Boom: Error {}

    private static let streamErrorCodeKey = "_kCFStreamErrorCodeKey"
    private static let pathKey = "_NSURLErrorNWPathKey"
    private static let operation = "native_exchange_api_auth_native_exchange_post"

    /// The denial exactly as the device reported it: -1009, ENETDOWN at connect, on a path the
    /// system itself calls satisfied.
    private static var denial: URLError {
        URLError(
            .notConnectedToInternet,
            userInfo: [streamErrorCodeKey: 50, pathKey: "satisfied"]
        )
    }

    /// What the generated client actually throws: the transport's error, wrapped.
    private func clientError(wrapping underlying: any Error) -> ClientError {
        ClientError(
            operationID: Self.operation,
            operationInput: ExchangeInput(),
            causeDescription: "Transport threw an error.",
            underlyingError: underlying
        )
    }

    @Test("ENETDOWN at connect on a -1009 is the denial, and the only thing that is")
    func denialIsRecognised() {
        #expect(
            NativeLoginTransportFailure.classify(clientError(wrapping: Self.denial))
                == .localNetworkDenied
        )
    }

    @Test("a -1009 on a satisfied path but WITHOUT the stream code is offline, not the denial")
    func satisfiedPathAloneIsNotTheDenial() {
        let error = URLError(.notConnectedToInternet, userInfo: [Self.pathKey: "satisfied"])
        #expect(NativeLoginTransportFailure.classify(clientError(wrapping: error)) == .offline)
    }

    @Test("a bare -1009 is offline")
    func plainNotConnectedIsOffline() {
        let error = URLError(.notConnectedToInternet)
        #expect(NativeLoginTransportFailure.classify(clientError(wrapping: error)) == .offline)
    }

    @Test("the stream code on any other URL error is not a denial either")
    func theStreamCodeAloneIsNotTheDenial() {
        let error = URLError(.cannotConnectToHost, userInfo: [Self.streamErrorCodeKey: 50])
        #expect(
            NativeLoginTransportFailure.classify(clientError(wrapping: error))
                == .other("NSURLErrorDomain -1004")
        )
    }

    @Test("a timeout is neither, and is named by its domain and code")
    func timeoutIsOther() {
        #expect(
            NativeLoginTransportFailure.classify(clientError(wrapping: URLError(.timedOut)))
                == .other("NSURLErrorDomain -1001")
        )
    }

    @Test("an error that is not a URL error at all is other, named by its own domain")
    func nonURLErrorIsOther() {
        let kind = NativeLoginTransportFailure.classify(clientError(wrapping: Boom()))
        guard case .other(let detail) = kind else {
            Issue.record("a non-URL error classified as \(kind)")
            return
        }
        #expect(detail.contains("Boom"))
    }

    @Test("the denial is recognised through a nested underlying error")
    func denialNestedUnderAnotherError() {
        let outer = NSError(
            domain: "kCFErrorDomainCFNetwork",
            code: -1009,
            userInfo: [NSUnderlyingErrorKey: Self.denial as NSError]
        )
        #expect(
            NativeLoginTransportFailure.classify(clientError(wrapping: outer))
                == .localNetworkDenied
        )
    }

    @Test("a transport error that arrives unwrapped classifies the same way")
    func bareURLErrorClassifies() {
        #expect(NativeLoginTransportFailure.classify(Self.denial) == .localNetworkDenied)
    }

    @Test("the diagnostic names the classification, the domain and the code — and nothing else")
    func diagnosticNamesOnlyTheSafeFacts() {
        let text = NativeLoginTransportFailure.diagnostic(for: clientError(wrapping: Self.denial))
        #expect(text.contains("NSURLErrorDomain"))
        #expect(text.contains("-1009"))
        #expect(text.contains("local-network-denied"))
    }

    @Test("nothing the classifier produces carries the handoff code, the verifier or the operation")
    func nothingProducedLeaksTheExchange() {
        let secrets = ["handoff-123", "verifier-abcdefghijklmnop", Self.operation]
        let raw = clientError(wrapping: Self.denial)
        // Positive control: the error itself DOES carry all three, so a leak is something this
        // test could actually see.
        let rawText = String(describing: raw)
        for secret in secrets {
            #expect(rawText.contains(secret), "the control error must carry \(secret)")
        }

        var produced = [NativeLoginTransportFailure.diagnostic(for: raw)]
        for error in [raw as any Error, URLError(.timedOut), Boom()] {
            let failure = NativeLoginTransportFailure.classify(error)
            produced.append(NativeLoginTransportFailure.diagnostic(for: error))
            if case .other(let detail) = failure { produced.append(detail) }
            if let message = NativeLoginError.transport(failure).message {
                produced.append(message)
            }
        }
        for text in produced {
            for secret in secrets {
                #expect(!text.contains(secret), "\(text) carries \(secret)")
            }
        }
    }
}
