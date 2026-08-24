import CryptoKit
import Foundation

/// The proof that the device which STARTED a login is the one collecting its result.
///
/// The challenge travels with the login through a browser; the verifier never leaves the device.
/// That is the whole reason this app can use an HTTPS callback safely: an intercepted handoff code
/// is inert without the verifier that produced its challenge (RFC 7636).
///
/// A reference type rather than a value: the flow that owns it destroys the verifier the moment
/// the exchange is over, and a struct copied into a closure would leave the caller holding a live
/// copy of exactly the secret that was supposed to be gone.
public final class PKCE: @unchecked Sendable {
    private let lock = NSLock()
    private var verifierBytes: [UInt8]

    /// The S256 challenge for this verifier. Not secret — it is in the login URL — and kept after
    /// `zeroize()` so a failure can still be reported against the login it belongs to.
    public let challenge: String

    /// A fresh verifier: 32 random bytes from `CryptoKit`, base64url-encoded to the 43 characters
    /// RFC 7636 §4.1 asks for.
    public convenience init() {
        self.init(randomBytes: SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    /// The deterministic door in, so the encoding can be held to the RFC's own vectors.
    public init(randomBytes: [UInt8]) {
        let verifier = Self.base64url(randomBytes)
        self.verifierBytes = Array(verifier.utf8)
        self.challenge = Self.s256Challenge(for: verifier)
    }

    /// The verifier, or `nil` once it has been destroyed.
    public var verifier: String? {
        lock.withLock {
            verifierBytes.isEmpty ? nil : String(decoding: verifierBytes, as: UTF8.self)
        }
    }

    /// Overwrites the verifier and forgets it.
    ///
    /// What this can promise is that THIS object stops holding the secret: the buffer is written
    /// over before it is released. What no managed language can promise is that the transient
    /// `String` copies handed to a JSON encoder along the way are gone too — so the flow calls
    /// this as soon as the exchange returns, rather than treating it as a complete erasure.
    public func zeroize() {
        lock.withLock {
            for index in verifierBytes.indices { verifierBytes[index] = 0 }
            verifierBytes.removeAll(keepingCapacity: false)
        }
    }

    /// The S256 code challenge for a verifier: un-padded base64url of its SHA-256. Pure.
    ///
    /// S256 only. `plain` is a downgrade this client cannot be talked into because it cannot
    /// express it, and the server computes S256 unconditionally.
    public static func s256Challenge(for verifier: String) -> String {
        base64url(Array(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Base64url without padding — the encoding RFC 7636 uses for both halves.
    public static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
