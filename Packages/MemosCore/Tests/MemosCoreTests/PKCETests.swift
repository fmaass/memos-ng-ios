import Foundation
import MemosAPI
import MemosCore
import Testing

/// PKCE against RFC 7636's own numbers.
///
/// The vectors are the point: an S256 challenge computed even slightly differently (padded
/// base64, standard alphabet, hashing the raw bytes instead of the encoded verifier) produces a
/// login that fails at the exchange with `verifier_mismatch` and no way to tell why from a phone.
@Suite("PKCE")
struct PKCETests {
    /// RFC 7636 Appendix B, the verifier's octets.
    private let appendixBOctets: [UInt8] = [
        116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37,
        77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121,
    ]
    private let appendixBVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private let appendixBChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    @Test("the RFC's octets encode to the RFC's verifier and challenge")
    func appendixB() {
        let pkce = PKCE(randomBytes: appendixBOctets)
        #expect(pkce.verifier == appendixBVerifier)
        #expect(pkce.challenge == appendixBChallenge)
    }

    @Test("the challenge function alone answers the RFC's known value")
    func knownAnswerChallenge() {
        #expect(PKCE.s256Challenge(for: appendixBVerifier) == appendixBChallenge)
    }

    @Test("base64url is un-padded and uses the URL alphabet")
    func base64urlAlphabet() {
        // 0xFB 0xFF encodes to "+/8=" in standard base64 — every character this must not emit.
        #expect(PKCE.base64url([0xFB, 0xFF]) == "-_8")
        #expect(PKCE.base64url([]) == "")
    }

    @Test("a generated verifier is 32 random bytes the server will accept")
    func generatedVerifierIsAcceptable() throws {
        let pkce = PKCE()
        let verifier = try #require(pkce.verifier)

        // 32 bytes base64url-encoded without padding is 43 characters, RFC 7636 §4.1's minimum.
        #expect(verifier.count == 43)
        #expect(NativeLogin.isValidCodeChallenge(verifier))
        #expect(NativeLogin.isValidCodeChallenge(pkce.challenge))
        #expect(PKCE.s256Challenge(for: verifier) == pkce.challenge)
    }

    @Test("two logins never share a verifier")
    func generatedVerifiersDiffer() {
        let verifiers = Set((0..<16).compactMap { _ in PKCE().verifier })
        #expect(verifiers.count == 16)
    }

    @Test("zeroizing destroys the verifier and keeps the challenge")
    func zeroize() {
        let pkce = PKCE(randomBytes: appendixBOctets)
        #expect(pkce.verifier != nil)

        pkce.zeroize()

        #expect(pkce.verifier == nil)
        #expect(pkce.challenge == appendixBChallenge, "the challenge is not secret and is kept")
        pkce.zeroize()
        #expect(pkce.verifier == nil, "zeroizing twice is not an error")
    }
}
