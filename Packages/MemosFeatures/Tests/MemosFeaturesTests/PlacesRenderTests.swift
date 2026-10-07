import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// What the Places screen offers, asserted through the values it is built from rather than through
/// pixels a headless run cannot see.
@MainActor
@Suite("Places screen")
struct PlacesRenderTests {
    /// The tab bar's own content, because `MainTabView.tabs` iterates `MainTab.allCases` — so this
    /// is not a statement about an enum nothing reads, it is a statement about the bar a person
    /// touches.
    @Test("the app offers a third way in, named Places, last in the bar after the timeline")
    func placesIsInTheTabBar() {
        #expect(MainTab.allCases.count == 4)
        let raw = MainTab.allCases.map(\.rawValue)
        #expect(raw == ["library", "collections", "timeline", "places"])
        #expect(MainTab.allCases.map(\.title) == ["Library", "Collections", "Timeline", "Places"])
    }
}
