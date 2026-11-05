import Foundation
import MemosAPI

/// The server this device last signed in to, kept so the sign-in field can offer it again.
///
/// It replaces a compiled-in household address: the app is installed by people with servers of
/// their own, and the field starts empty for them. The household keeps its muscle memory because
/// every session this device establishes, a launch restoring a stored account included, writes
/// its server here.
///
/// A convenience and never a trust anchor. Nothing is authorised because an address was
/// remembered: it is prefilled into an editable field, and a sign-in to it goes through the same
/// handshake and the same server answer as one to an address typed by hand.
///
/// `UserDefaults`, not the keychain. The vault holds the token and its server as ONE pair, written
/// and removed together, and a sign-out empties it; this outlives a sign-out on purpose, holds
/// nothing secret, and names no account — a host, not who signed in to it.
@MainActor
public final class ServerAddressMemory {
    public nonisolated static let defaultsKey = "sign-in.last-server-address"

    private let defaults: UserDefaults?
    private let key: String
    /// Where the address lives without a `UserDefaults`: a suite's memory, gone with the object.
    private var held: String?

    /// `defaults: nil` remembers for this object's lifetime only, which is what a test wants.
    public init(defaults: UserDefaults? = nil, key: String = ServerAddressMemory.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The remembered address as the field shows it, or `nil`. Read through
    /// `ServerConfiguration` so a value that would not parse is never offered.
    public var lastUsed: String? {
        let stored: String?
        if let defaults {
            stored = defaults.string(forKey: key)
        } else {
            stored = held
        }
        return stored.flatMap(ServerConfiguration.init(serverAddress:))?.displayAddress
    }

    func remember(_ configuration: ServerConfiguration) {
        let address = configuration.displayAddress
        held = address
        defaults?.set(address, forKey: key)
    }
}
