import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// Where the live media channel learns whether the app is in front of anybody.
///
/// It is one initialiser, and it is tested because it is where a real decision is made rather than
/// a rename: reading `inactive` as background would tear the connection down and build it up again
/// every time somebody glanced at another app.
@Suite("Media channel scene phase")
struct MediaChannelSceneTests {
    @Test("every scene phase maps to the phase the channel reasons about")
    func everyScenePhaseIsMapped() {
        #expect(MediaChannelPhase(ScenePhase.active) == .active)
        #expect(MediaChannelPhase(ScenePhase.inactive) == .inactive)
        #expect(MediaChannelPhase(ScenePhase.background) == .background)
    }

    /// The pair, read the way the view reads it: the mapping and the rule it feeds are only right
    /// together, and this is the one place both halves are in view.
    @Test("the app switcher keeps the channel; going to the background ends it")
    func theSwitcherDoesNotEndTheChannel() {
        func runs(_ phase: ScenePhase) -> Bool {
            MediaChannel.shouldRun(
                phase: MediaChannelPhase(phase),
                signedIn: true,
                hasTimeline: true
            )
        }
        #expect(runs(.active))
        #expect(runs(.inactive))
        #expect(!runs(.background))
    }
}
