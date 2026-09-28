import MemosCore
import Testing

// The vectors are the web's own: frontend/src/lib/__tests__/dockState.spec.ts (memos-ng 88453df),
// with its routes mapped onto the tabs — `/resources` is `.library`, `/` is `.timeline`, `/places`
// is `.places`. Two of its routes have no native destination: `/resources/x` and `/search` stand
// for "a route that is not the Library", and `MainTab` has three cases and no fourth to observe a
// scroll on. They are listed in `webOnlyRoutes` below rather than dropped, and the two tabs that
// DO exist carry that vector instead.
@Suite("DockMode")
struct DockModeTests {
    private let threshold = DockMode.segmentThreshold

    @Test("the threshold is the web's 24")
    func threshold24() {
        #expect(DockMode.segmentThreshold == 24)
    }

    @Test("starts in tabs")
    func startsInTabs() {
        #expect(DockMode.initial == .tabs)
    }

    @Test("enters segment the moment the Library is scrolled past the threshold")
    func entersSegmentPastThreshold() {
        #expect(DockMode.tabs.after(.scroll(y: threshold + 1, tab: .library)) == .segment)
        #expect(DockMode.segment.after(.scroll(y: 5000, tab: .library)) == .segment)
    }

    @Test("returns to tabs at the top of the Library")
    func returnsToTabsAtTheTop() {
        #expect(DockMode.segment.after(.scroll(y: 0, tab: .library)) == .tabs)
        // Rubber-banding reports a negative offset at the top.
        #expect(DockMode.segment.after(.scroll(y: -40, tab: .library)) == .tabs)
    }

    @Test("leaves the mode unchanged between the top and the threshold")
    func unchangedBetweenTopAndThreshold() {
        for y in [1, threshold / 2, threshold] {
            #expect(DockMode.tabs.after(.scroll(y: y, tab: .library)) == .tabs, "y=\(y)")
            #expect(DockMode.segment.after(.scroll(y: y, tab: .library)) == .segment, "y=\(y)")
        }
    }

    @Test("toggles on a tap of the active Library tab")
    func togglesOnTapActive() {
        #expect(DockMode.tabs.after(.tapActive(.library)) == .segment)
        #expect(DockMode.segment.after(.tapActive(.library)) == .tabs)
    }

    @Test("goes back to segment on the next scroll past the threshold after a mid-page tap")
    func segmentAgainAfterMidPageTap() {
        // Intended: a tap expands the tabs until the next scroll (plan page 3929 decision 8).
        var mode = DockMode.tabs.after(.scroll(y: 800, tab: .library))
        #expect(mode == .segment)
        mode = mode.after(.tapActive(.library))
        #expect(mode == .tabs)
        mode = mode.after(.scroll(y: 820, tab: .library))
        #expect(mode == .segment)
    }

    @Test("resets to tabs on leaving the Library")
    func resetsOnLeavingLibrary() {
        #expect(DockMode.segment.after(.leaveLibrary) == .tabs)
        #expect(DockMode.tabs.after(.leaveLibrary) == .tabs)
    }

    @Test(
        "returns the mode unchanged for a scroll or a tap observed on another tab",
        arguments: [MainTab.timeline, MainTab.places]
    )
    func unchangedOffTheLibrary(tab: MainTab) {
        for mode in [DockMode.tabs, DockMode.segment] {
            #expect(mode.after(.scroll(y: 5000, tab: tab)) == mode, "\(mode) on \(tab)")
            #expect(mode.after(.scroll(y: 0, tab: tab)) == mode, "\(mode) on \(tab)")
            #expect(mode.after(.tapActive(tab)) == mode, "\(mode) on \(tab)")
        }
    }

    /// The web spec's rows for routes the native app cannot be on. Not applicable, not forgotten:
    /// `MainTab` is the whole of what a scroll can be observed on, so a fourth route would be a
    /// fourth case — and adding one fails `mapsEveryTab` below until it is mapped here or above.
    static let webOnlyRoutes = ["/resources/x", "/search"]

    @Test("every tab is covered by a vector, and the web-only routes are recorded as such")
    func mapsEveryTab() {
        #expect(MainTab.allCases == [.library, .timeline, .places])
        #expect(Self.webOnlyRoutes == ["/resources/x", "/search"])
    }
}
