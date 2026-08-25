import MemosCore
import SwiftUI

extension MediaChannelPhase {
    /// SwiftUI's scene phase as the one the channel reasons about.
    ///
    /// Its own function, and tested, because it is where a foreground decision is actually made:
    /// `inactive` is the app switcher and the notification shade, and reading it as background is
    /// what would tear the connection down and rebuild it every time somebody glanced at another
    /// app — see `MediaChannel.shouldRun`, which is the half that decides.
    ///
    /// An unknown future phase is read as `inactive`, the conservative one: it leaves an open
    /// channel open, and the server ends an idle stream by itself, so the cost of being wrong that
    /// way is one connection that closes a little later than it might have.
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        @unknown default: self = .inactive
        }
    }
}
