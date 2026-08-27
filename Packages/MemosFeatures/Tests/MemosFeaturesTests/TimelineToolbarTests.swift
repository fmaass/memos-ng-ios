import Foundation
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Which end of the timeline's top bar each control sits at — measured in a real
/// `UINavigationBar` rather than asserted against a list this file also wrote.
///
/// The arrangement is an IA decision (see `TimelineToolbar`): the way into Settings LEADING, New
/// memo TRAILING and rightmost, and the slot between them held empty for the date-jump / search
/// loupe. That is exactly the kind of decision a refactor undoes in silence — both controls were
/// on the right until 2026-08-26, and nothing short of a screenshot would have said so.
///
/// MEMNG-185 changed WHAT sits in the leading corner — a gear rather than the account's face, and
/// a straight navigation rather than a menu — without changing where anything sits. The placement
/// assertions below are unchanged for that reason; what is new is that pressing the thing is
/// tested rather than only its presence.
///
/// MEASURED, not read out of `UINavigationItem`. A SwiftUI `.toolbar` on iOS 26 leaves
/// `leftBarButtonItems` and `rightBarButtonItems` EMPTY — both were 0 with two `.topBarTrailing`
/// items, so a count of them says nothing about placement in either direction (observed on this
/// suite's own first run, 2026-08-26; the counts are still printed by `describe` for whoever
/// reads a failure). What the bar does report honestly is where things landed, and left of / right
/// of is what the decision is about anyway.
///
/// `TimelineView` itself cannot be hosted here: it reads `SessionStore` from the environment, and
/// constructing one inlines `APIClientFactory.make` from the API layer this bundle deliberately
/// does not link (the same wall `SettingsRenderTests` documents). `TimelineToolbar` exists so the
/// placements do not have to live behind it — it is the toolbar the screen applies, hosted here
/// with plain values in place of the session.
@MainActor
@Suite("The timeline's toolbar")
struct TimelineToolbarTests {
    /// A hosted bar, with the window that owns it kept alive: a `UINavigationBar` whose window
    /// has been released is a bar whose controls have gone with it, and the assertions would read
    /// an empty one as a placement failure.
    private struct HostedBar {
        let window: UIWindow
        let bar: UINavigationBar
    }

    /// One control as VoiceOver and the layout see it: what it is called, and where it ended up.
    private struct Control {
        let label: String
        let frame: CGRect
    }

    /// Everything the bar shows, and the line down its middle that "leading" and "trailing" are
    /// on opposite sides of.
    private struct BarContents {
        let controls: [Control]
        let middle: CGFloat
        let description: String

        func control(_ label: String) -> Control? {
            controls.first(where: { $0.label == label })
        }
    }

    private func toolbar() -> TimelineToolbar {
        TimelineToolbar(composed: 0, openSettings: {}, search: {}, newMemo: {})
    }

    /// Hosted in a real key window and laid out around a run-loop spin, for the reason
    /// `SettingsRenderTests` gives: UIKit finishes a navigation bar a turn after the hierarchy
    /// exists, and a bar read before that is empty for reasons of timing rather than of placement.
    private func host(_ toolbar: TimelineToolbar) -> HostedBar? {
        let root = NavigationStack {
            Color(.systemGroupedBackground)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        let frame = CGRect(x: 0, y: 0, width: 393, height: 400)
        let controller = UIHostingController(rootView: root)
        controller.view.frame = frame
        let window = UIWindow(frame: frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        guard let bar = Self.navigationBar(in: window) else { return nil }
        return HostedBar(window: window, bar: bar)
    }

    private static func navigationBar(in view: UIView) -> UINavigationBar? {
        if let bar = view as? UINavigationBar { return bar }
        for subview in view.subviews {
            if let found = navigationBar(in: subview) { return found }
        }
        return nil
    }

    /// Everything in the bar that answers to VoiceOver, with its frame in window coordinates —
    /// which is what makes "left of" a measurement rather than a reading of the source.
    private static func controls(in bar: UINavigationBar) -> [Control] {
        var found: [Control] = []
        func walk(_ view: UIView) {
            if let label = view.accessibilityLabel, !label.isEmpty {
                found.append(Control(label: label, frame: view.convert(view.bounds, to: nil)))
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(bar)
        return found
    }

    /// What the bar turned out to hold, printed with every failure so it says which arrangement
    /// was read rather than only that a number was wrong.
    private static func describe(_ bar: UINavigationBar, controls: [Control]) -> String {
        let item = bar.topItem ?? bar.items?.last
        var lines = [
            "topItem: \(item == nil ? "none" : "present")",
            "barButtonItems: left=\((item?.leftBarButtonItems ?? []).count)"
                + " right=\((item?.rightBarButtonItems ?? []).count)",
            "itemGroups: leading=\((item?.leadingItemGroups ?? []).count)"
                + " trailing=\((item?.trailingItemGroups ?? []).count)",
        ]
        for control in controls {
            lines.append("control '\(control.label)' x=\(control.frame.minX)")
        }
        return lines.joined(separator: "\n")
    }

    private func contents(of hosted: HostedBar) -> BarContents {
        let controls = Self.controls(in: hosted.bar)
        return BarContents(
            controls: controls,
            middle: hosted.bar.convert(hosted.bar.bounds, to: nil).midX,
            description: Self.describe(hosted.bar, controls: controls)
        )
    }

    private func hostedBar() throws -> BarContents {
        let hosted = try #require(host(toolbar()), "the toolbar produced no bar")
        return contents(of: hosted)
    }

    /// The assertion the move is for: the way into Settings is in the LEADING half of the bar,
    /// not wedged against the button at the other end of it. This is what fails on the old
    /// arrangement.
    @Test("the settings button is the leading control")
    func settingsIsTheLeadingControl() throws {
        let bar = try hostedBar()
        print("MEMOSNG_TOOLBAR_BEGIN\n\(bar.description)\nMEMOSNG_TOOLBAR_END")
        let account = try #require(
            bar.control("Settings"),
            "no control called Settings: \(bar.description)"
        )
        let newMemo = try #require(
            bar.control("New memo"),
            "no control called New memo: \(bar.description)"
        )

        #expect(account.frame.midX < bar.middle, "the gear is not in the leading half")
        #expect(account.frame.minX < newMemo.frame.minX, "the gear is not left of New memo")
    }

    /// The other half of the same decision, and the reservation that goes with it: New memo is in
    /// the trailing half and nothing sits to its right, because the slot the loupe (MEMNG-120)
    /// will take is to its LEFT. A loupe added on the far side would fail here.
    @Test("New memo is the trailing control, and the rightmost thing in the bar")
    func newMemoIsTheRightmostControl() throws {
        let bar = try hostedBar()
        let newMemo = try #require(
            bar.control("New memo"),
            "no control called New memo: \(bar.description)"
        )

        #expect(newMemo.frame.midX > bar.middle, "New memo is not in the trailing half")
        #expect(
            bar.controls.allSatisfy({ $0.frame.maxX <= newMemo.frame.maxX }),
            "something sits to the right of New memo: \(bar.description)"
        )
    }

    /// Changing a control is a chance to lose the words VoiceOver reads, because the label is on
    /// the button rather than on the glyph inside it — an `Image(systemName:)` reads as nothing
    /// worth hearing on its own.
    @Test("both controls keep the words VoiceOver reads")
    func voiceOverLabelsSurvive() throws {
        let bar = try hostedBar()
        let labels = Set(bar.controls.map(\.label))

        #expect(labels.contains("Settings"), "\(bar.description)")
        #expect(labels.contains("New memo"), "\(bar.description)")
        // Positive control: the walk above reaches labelled views at all, so a label it does not
        // find is an absence rather than a walk that visited nothing.
        #expect(!labels.isEmpty)
    }

    /// The loupe MEMNG-120 reserved the slot for, arriving where the reservation said it would:
    /// in the trailing corner, immediately LEFT of New memo, which stays the rightmost thing in
    /// the bar. The leading corner is untouched.
    ///
    /// "The only new bar item" is the half a placement test usually misses. A search surface is
    /// easy to ship as two controls — a loupe and a cancel, or a loupe and a filter — and a bar
    /// with four things in it is a different screen from the one this arrangement was decided
    /// for. So the set of labels is asserted WHOLE rather than by looking for the new one.
    @Test("the corner button is the only new bar item and it is labelled for VoiceOver")
    func theLoupeIsTheOnlyNewBarItem() throws {
        let bar = try hostedBar()
        print("MEMOSNG_TOOLBAR_BEGIN\n\(bar.description)\nMEMOSNG_TOOLBAR_END")
        let labels = bar.controls.map(\.label)

        // Three, and exactly these three. A fourth control, or a second copy of one of them,
        // fails here rather than in a screenshot nobody takes.
        #expect(Set(labels) == ["Settings", "Search", "New memo"], "\(bar.description)")
        #expect(labels.count == 3, "a control is drawn twice: \(bar.description)")

        let account = try #require(bar.control("Settings"), "\(bar.description)")
        let search = try #require(bar.control("Search"), "\(bar.description)")
        let newMemo = try #require(bar.control("New memo"), "\(bar.description)")

        // Trailing corner, between the face and New memo — the reserved slot, in that order.
        #expect(search.frame.midX > bar.middle, "the loupe is not in the trailing half")
        #expect(account.frame.midX < search.frame.midX, "the loupe is not right of the gear")
        #expect(search.frame.midX < newMemo.frame.midX, "the loupe is not left of New memo")
        #expect(
            bar.controls.allSatisfy({ $0.frame.maxX <= newMemo.frame.maxX }),
            "the loupe displaced New memo from the right-hand end: \(bar.description)"
        )
    }

    /// The half a placement test cannot reach: the gear is not a PICTURE of a way into Settings,
    /// pressing it has to BE the way there. So the button is pressed the way VoiceOver presses it
    /// and the navigation the screen handed the toolbar is watched for — a gear wired to nothing
    /// fails here rather than in a screenshot nobody takes.
    ///
    /// Pressed on `SettingsToolbarButton` hosted alone rather than through the bar above, because
    /// SwiftUI's bar-item host carries the label but refuses activation: driven through the bar,
    /// this passes for a wired and an unwired gear alike. The bar tests hold WHERE it is and what
    /// it is called; this holds what it does.
    @Test("pressing the settings button performs the navigation")
    func pressingSettingsNavigates() {
        let navigation = NavigationSpy()
        let pressed = PressProbe.withElement(
            labelled: "Settings",
            in: SettingsToolbarButton(openSettings: { navigation.open() })
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the settings button refused an activation")
        #expect(navigation.opened == 1, "pressing the gear did not open Settings")
    }
}

/// What the screen does when the toolbar asks for Settings, standing in for the navigation path
/// `TimelineView` appends to — which cannot be reached from here, since that screen needs a
/// `SessionStore` this bundle cannot build.
@MainActor
private final class NavigationSpy {
    private(set) var opened = 0

    func open() { opened += 1 }
}
