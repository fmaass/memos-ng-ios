import Foundation
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The accent is the one owned colour in the app, and "owned" only means something while it can be
/// read back. These tests hold it to the two hex values that were approved, in both catalogues it
/// is declared in, and hold a Markdown link to it — a system-blue fallback fails every one.
@MainActor
@Suite("Design tokens")
struct DesignTokensTests {
    private static let approvedLight = (r: 0x3E, g: 0x7C, b: 0x4F)
    private static let approvedDark = (r: 0x7F, g: 0xB0, b: 0x8C)

    private func components(
        _ color: UIColor,
        _ style: UIUserInterfaceStyle
    ) -> (r: Int, g: Int, b: Int) {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (
            Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())
        )
    }

    @Test("the accent asset exists and is the approved green in both appearances")
    func accentAssetIsTheApprovedColour() throws {
        let accent = try #require(
            UIColor(named: "AccentColor", in: DesignTokens.assetBundle, compatibleWith: nil),
            "the package's AccentColor asset is missing"
        )
        let light = components(accent, .light)
        let dark = components(accent, .dark)
        #expect(light == Self.approvedLight)
        #expect(dark == Self.approvedDark)
        // It is a real appearance-aware asset, not one colour wearing two names.
        #expect(light != dark)
    }

    /// The accent is declared twice on purpose — the app's catalogue is what the SYSTEM reads for
    /// the global tint, the package's is what this code resolves. Two declarations can drift; this
    /// is the check that says they have not.
    @Test("the app's global accent and the package's accent are the same colour")
    func theTwoCataloguesAgree() throws {
        let app = try #require(
            UIColor(named: "AccentColor", in: .main, compatibleWith: nil),
            "the app target's AccentColor asset is missing"
        )
        let package = try #require(
            UIColor(named: "AccentColor", in: DesignTokens.assetBundle, compatibleWith: nil)
        )
        #expect(components(app, .light) == components(package, .light))
        #expect(components(app, .dark) == components(package, .dark))
        #expect(components(app, .light) == Self.approvedLight)
        #expect(components(app, .dark) == Self.approvedDark)
    }

    /// This is the same call MarkdownUI's own inline renderer makes when it paints a link
    /// (`AttributedStringInlineRenderer` merges `theme.link` into the run), so what comes back IS
    /// the colour a link in a memo will be drawn in. Before this phase nothing set it at all and
    /// the container came back with no foreground colour — the system blue that clashed with the
    /// green icon. That state fails the first assertion here.
    @Test("a markdown link resolves to the accent, not to the system default")
    func markdownLinksArePaintedInTheAccent() throws {
        let attributes = MemoMarkdownTheme.linkAttributes()
        let colour = try #require(
            attributes.foregroundColor,
            "the memo theme leaves link colour to the system"
        )
        #expect(colour == DesignTokens.accent)
        #expect(colour != Color.blue)
        #expect(colour != Color.primary)
    }

    @Test("the design scale is concentric and ordered, not a pile of literals")
    func scalesAreOrdered() {
        #expect(DesignTokens.Space.hair < DesignTokens.Space.tight)
        #expect(DesignTokens.Space.tight < DesignTokens.Space.snug)
        #expect(DesignTokens.Space.snug < DesignTokens.Space.regular)
        #expect(DesignTokens.Space.regular < DesignTokens.Space.roomy)
        #expect(DesignTokens.Space.roomy < DesignTokens.Space.section)
        // A tile sits inside a card, so its radius has to be the smaller of the two for the two
        // curves to read as parallel rather than nested.
        #expect(DesignTokens.Radius.tile < DesignTokens.Radius.card)
        #expect(DesignTokens.Radius.card >= 18 && DesignTokens.Radius.card <= 22)
    }
}

@MainActor
@Suite("Haptic vocabulary")
struct HapticSignalTests {
    @Test("every act has the feel it should, and no two opposites share one")
    func theTable() {
        #expect(MemoAct.posted.kind == .success)
        #expect(MemoAct.postFailed.kind == .error)
        #expect(MemoAct.deleted.kind == .warning)
        #expect(MemoAct.pinned.kind == .lightImpact)
        #expect(MemoAct.unpinned.kind == .lightImpact)
        #expect(MemoAct.taskChecked.kind == .mediumImpact)
        #expect(MemoAct.taskUnchecked.kind == .lightImpact)
        // A scrub crosses dozens of days in one gesture: an impact per day would be a rumble.
        #expect(MemoAct.dayScrubbed.kind == .selection)
        #expect(MemoAct.dayScrubbed.kind != MemoAct.taskChecked.kind)
        // Deleting must never feel like success — the two are the pair most easily confused.
        #expect(MemoAct.deleted.kind != MemoAct.posted.kind)
        #expect(MemoAct.postFailed.kind != MemoAct.posted.kind)
    }

    @Test("every act is covered, so a new one cannot arrive silent")
    func everyActIsMapped() {
        for act in MemoAct.allCases {
            #expect(FeedbackKind.allCases.contains(act.kind))
        }
    }

    @Test("the same act twice is two events")
    func repeatsRetrigger() {
        var trigger = MemoFeedbackTrigger()
        #expect(trigger.act == nil)
        #expect(trigger.count == 0)
        trigger.fire(.pinned)
        let first = trigger
        trigger.fire(.pinned)
        #expect(trigger.act == .pinned)
        #expect(trigger != first)
        #expect(trigger.count == 2)
    }
}
