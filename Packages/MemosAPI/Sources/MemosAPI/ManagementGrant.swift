import Foundation

/// The step-up management credential, for as long as a management screen is open — and nowhere
/// else, ever.
///
/// It is bought with a fresh household sign-on rather than derived from anything this device
/// already holds (ADR-0015: a device token mints and revokes nothing but itself), and it is the
/// authority behind every `/api/pats` call the app makes. What makes that safe is how briefly it
/// exists: the server gives it minutes, and this object is the only copy on the device.
///
/// So it is deliberately NOT a `PresentedCredential`. That one is the session's token — written to
/// the Keychain, restored at launch, presented by every client in the process. This one is written
/// nowhere. It is not in the Keychain, not in `UserDefaults`, not in the app group, not in a file.
/// It dies when the screen holding it goes away, when the app is backgrounded, when its deadline
/// passes and when the process ends, and the only way to have one again is another sign-on. A grant
/// that survived any of those would be a long-lived management capability sitting on a phone, which
/// is precisely the thing this design exists to avoid.
///
/// The deadline is the SERVER's, carried in the mint response rather than guessed here, because the
/// server's is the only one that decides anything. Holding it lets the screen say "that management
/// session has ended" instead of collecting a 401 for something it could already know.
///
/// A locked class rather than an actor, for the reason `PresentedCredential` is one: the middleware
/// reads it on every request from whatever executor the transport is running on, and an actor would
/// put a suspension point on that path.
public final class ManagementGrant: @unchecked Sendable {
    private let lock = NSLock()
    /// Bytes rather than a `String`, so that forgetting one can overwrite it — the same bargain
    /// `PKCE` makes, and with the same honesty about its limit: this object stops holding the
    /// secret, and no managed language can promise the transient copies handed to a header encoder
    /// along the way are gone too.
    private var value: [UInt8] = []
    private var deadline: Date?

    public init() {}

    /// What the next request will present, or `nil` when there is nothing to present.
    public var current: String? {
        lock.withLock { value.isEmpty ? nil : String(decoding: value, as: UTF8.self) }
    }

    /// When the server said this grant stops working, or `nil` when none is held.
    public var expiry: Date? { lock.withLock { value.isEmpty ? nil : deadline } }

    /// Takes a freshly minted grant and the deadline it came with.
    public func hold(_ grant: String, until expiresAt: Date) {
        lock.withLock {
            zeroLocked()
            value = Array(grant.utf8)
            deadline = expiresAt
        }
    }

    /// Drops it: the screen went away, the app was backgrounded, or the server refused it.
    public func forget() {
        lock.withLock {
            zeroLocked()
            deadline = nil
        }
    }

    /// Whether there is a grant here that has not run out yet. False is the honest re-authenticate
    /// state; it is never a reason to keep asking.
    public func isLive(at now: Date) -> Bool {
        lock.withLock {
            guard !value.isEmpty, let deadline else { return false }
            return now < deadline
        }
    }

    private func zeroLocked() {
        for index in value.indices { value[index] = 0 }
        value.removeAll(keepingCapacity: false)
    }
}
