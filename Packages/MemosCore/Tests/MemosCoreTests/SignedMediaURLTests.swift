import Foundation
import MemosCore
import Testing

@Suite("SignedMediaURL")
struct SignedMediaURLTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func signed(expiringIn seconds: TimeInterval) -> SignedMediaURL {
        let exp = Int(now.timeIntervalSince1970 + seconds)
        let string = "https://memos.example.com/api/attachments/abc/thumb?exp=\(exp)&sig=deadbeef"
        return SignedMediaURL(url: URL(string: string)!)
    }

    @Test("reads the expiry out of the signed URL")
    func parsesExpiry() {
        let url = signed(expiringIn: 600)
        #expect(url.expiresAt == Date(timeIntervalSince1970: now.timeIntervalSince1970 + 600))
    }

    @Test("a URL with no exp has no expiry and no signature-derived lifetime")
    func unsigned() {
        let url = SignedMediaURL(url: URL(string: "https://memos.example.com/logo.png")!)
        #expect(url.expiresAt == nil)
        #expect(url.remainingLifetime(at: now) == nil)
        #expect(!url.isExpired(at: now))
    }

    @Test("a cached entry can never outlive the signature")
    func lifetimeIsBoundedByTheSignature() {
        let url = signed(expiringIn: 600)
        // The server may advertise a whole day of caching; the signature says ten minutes.
        #expect(url.cacheLifetime(at: now, serverMaxAge: 86_400) == 600)
        #expect(url.cacheLifetime(at: now, serverMaxAge: 60) == 60)
        #expect(url.cacheLifetime(at: now, serverMaxAge: nil) == 600)
    }

    @Test("an expired signature caches for nothing and bypasses the cache")
    func expired() {
        let url = signed(expiringIn: -1)
        #expect(url.isExpired(at: now))
        #expect(url.remainingLifetime(at: now) == 0)
        #expect(url.cacheLifetime(at: now, serverMaxAge: 86_400) == 0)
        #expect(url.cachePolicy(at: now) == .reloadIgnoringLocalCacheData)
    }

    @Test("a live signature uses the ordinary protocol cache policy")
    func live() {
        #expect(signed(expiringIn: 600).cachePolicy(at: now) == .useProtocolCachePolicy)
    }

    @Test("a negative server max-age never becomes a negative lifetime")
    func negativeMaxAge() {
        #expect(signed(expiringIn: 600).cacheLifetime(at: now, serverMaxAge: -10) == 0)
    }
}
