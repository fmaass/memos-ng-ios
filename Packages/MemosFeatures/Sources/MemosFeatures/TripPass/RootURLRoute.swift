import Foundation
import MemosOutbox

/// Where a URL the app is opened with goes: a trip pass to guest mode, everything else to the
/// native sign-in's inbox exactly as before.
///
/// Pure, so both arms are asserted without a scene: a pass link must never reach the sign-in inbox
/// (which would drop it), and no sign-in callback may ever be read as a pass. The one rule about
/// what a pass link looks like is `GuestDoor.secret(fromPassLink:)`'s, not this file's.
enum RootURLRoute: Equatable {
    case tripPass(String)
    case inbox

    static func route(_ url: URL) -> RootURLRoute {
        if let secret = GuestDoor.secret(fromPassLink: url) { return .tripPass(secret) }
        return .inbox
    }
}
