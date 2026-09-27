import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Hosting the grid in a real window and asserting tiles get PLACED — the pass MEMNG-206 proved
/// was missing: the solver had tests, the tiles had tests, and the round trip that turns a store
/// full of files into laid-out rows had none, so a width that never lifted off zero shipped as a
/// library that renders nothing.
@MainActor
@Suite("Library grid placement")
struct MediaLibraryRenderTests {
    /// The grid under a namespace, which only a view can declare.
    private struct Harness: View {
        let items: [LibraryRow]
        var landing: LibraryLanding?
        var landed: (LibraryLanding) -> Void = { _ in }
        @Namespace private var zoom

        var body: some View {
            LibraryGrid(
                items: items,
                timeZone: MediaLibraryRenderTests.zone,
                errorText: nil,
                loadingMore: false,
                zoom: zoom,
                wantsMore: { _ in false },
                open: { _ in },
                fetch: { _, _ in },
                loadMore: {},
                landing: landing,
                landed: landed
            )
        }
    }

    /// The library the defect shipped against, in miniature: photographs in their own shapes, a
    /// clip, and a file with no dimensions at all (a migrated original the server never measured).
    /// All of it taken in one month, so it is one section under one header.
    private static let items: [LibraryRow] = [
        MediaViewerPageTests.image("lib-a", width: 4000, height: 3000),
        MediaViewerPageTests.image("lib-b", width: 3000, height: 4000),
        MediaViewerPageTests.image("lib-c", width: 8192, height: 2048),
        MediaViewerPageTests.image("lib-d", width: 2000, height: 2000),
        MediaViewerPageTests.video("lib-e"),
        MediaViewerPageTests.image("lib-f", width: 4032, height: 3024),
        MediaViewerPageTests.other("lib-g", mime: "application/pdf"),
        MediaViewerPageTests.image("lib-h", width: 2448, height: 3264),
    ].map { MediaLibraryRenderTests.row($0, takenAt: MediaLibraryRenderTests.september) }

    /// A fixed zone, so what month a fixture falls in does not depend on the simulator's.
    private static let zone = "Europe/Zurich"
    /// Mid-month in either zone a reader could be in, so no fixture sits on a month's edge.
    private static let september = Date(timeIntervalSince1970: 1_789_387_200)  // 2026-09-14 12:00Z
    private static let august = Date(timeIntervalSince1970: 1_786_708_800)  // 2026-08-14 12:00Z

    private static func row(_ attachment: MemoAttachment, takenAt: Date) -> LibraryRow {
        LibraryRow(
            attachment: attachment, takenAt: takenAt, mine: true, filename: attachment.uid)
    }

    /// MEMNG-587: the Months tap builds a NEW grid, and the jump may have landed before it exists
    /// or before it has measured its width. Either way the landing is already set when the grid
    /// could first scroll, so a grid that only answers a CHANGE of landing never scrolls at all.
    @Test("a grid built with a landing already set scrolls to it, once")
    func gridScrollsToALandingItWasBuiltWith() async throws {
        let filler = (0..<40).map {
            Self.row(
                MediaViewerPageTests.image("fill-\($0)", width: 1000, height: 1000),
                takenAt: Self.september)
        }
        let target = Self.row(
            MediaViewerPageTests.image("target", width: 1000, height: 1000), takenAt: Self.august)
        let landing = LibraryLanding(day: "2026-08-14", rowID: "target", serial: 1)
        let consumed = LockedLandings()
        // On the test host's own scene (as `StackChromeTests` does): a window belonging to no scene
        // took the first scroll the grid asked for and none after it.
        let frame = CGRect(origin: .zero, size: CGSize(width: 390, height: 844))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene })
            as? UIWindowScene
        {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = UIHostingController(
            rootView: Harness(
                items: filler + [target], landing: landing, landed: { consumed.append($0) }))
        window.makeKeyAndVisible()

        // The row coming into view is told after the scroll lands, so both are waited for; then a
        // few more passes, in which a second report of the same landing would arrive.
        // The landing's row is the grid's last, so a scroll brought to it rests at the bottom.
        var offset: CGFloat = 0
        var bottom: CGFloat = .infinity
        var settledPasses = 0
        for _ in 0..<80 where settledPasses < 5 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            (offset, bottom) = Self.scrollOffset(in: window)
            if offset >= bottom - 1, !consumed.all.isEmpty { settledPasses += 1 }
        }
        window.isHidden = true
        #expect(offset > 0, "the grid never scrolled to the landing it was built with")
        #expect(offset >= bottom - 1, "the scroll stopped short of the landing's row")
        #expect(consumed.all == [landing], "the landing was not reported scrolled to exactly once")
    }

    @Test("a grid holding files places them once it has a real frame")
    func gridPlacesTilesInARealFrame() async throws {
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(rootView: Harness(items: Self.items))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // What the solver itself packs for the width the grid must derive: the window's 390,
        // less the grid's own horizontal padding either side. The grid draws that packing as a
        // scroll whose content is each month's header and rows, the gaps between them and the
        // stack's vertical padding — so the content height IS the placement, readable from
        // outside the hierarchy. A header's height is the one number the solver does not know,
        // so it is measured, by UIKit, at the same width.
        let gap = DesignTokens.Space.tight
        let width = 390 - 2 * gap
        let sections = MediaLibraryPresentation.sections(
            for: Self.items, width: Double(width), gap: Double(gap), timeZone: Self.zone)
        let solved = sections.flatMap(\.rows)
        #expect(!solved.isEmpty, "the fixture must solve to rows — otherwise this asserts nothing")
        let header = LayoutProbe.size(
            LibraryMonthHeader(label: "September 2026"), width: width, height: LayoutProbe.unbounded
        ).height
        let stacked = solved.count + sections.count
        let expected =
            solved.reduce(CGFloat(0)) { $0 + CGFloat($1.height) }
            + CGFloat(sections.count) * header
            + CGFloat(stacked - 1) * gap + 2 * gap

        var placed: CGFloat = 0
        for _ in 0..<60 where abs(placed - expected) > 2 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            placed = Self.scrollContentHeight(in: window)
        }
        window.isHidden = true
        #expect(
            abs(placed - expected) <= 2,
            "the grid placed \(placed)pt of content where the solver packs \(expected)pt")
    }

    @Test("a two-month page shows a header per month, in the list's order")
    func headerPerMonth() async throws {
        let september = (0..<3).map {
            Self.row(
                MediaViewerPageTests.image("sep-\($0)", width: 4000, height: 3000),
                takenAt: Self.september)
        }
        let august = (0..<3).map {
            Self.row(
                MediaViewerPageTests.image("aug-\($0)", width: 3000, height: 4000),
                takenAt: Self.august)
        }
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(
            rootView: Harness(items: september + august))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        let months: Set<String> = ["September 2026", "August 2026"]
        var headers: [String] = []
        for _ in 0..<60 where headers.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            var found: [String] = []
            Self.collectLabels(window, into: &found)
            headers = found.filter(months.contains).reduce(into: []) { seen, label in
                if !seen.contains(label) { seen.append(label) }
            }
        }
        window.isHidden = true
        // Newest first, as the list came: a grid that re-sorted its sections, or drew one header
        // for the whole page, fails here.
        #expect(headers == ["September 2026", "August 2026"])
    }

    /// Every label the hosted hierarchy reads out, in the order it offers them — the walk
    /// `LayoutProbe.reads` makes, collecting rather than searching.
    private static func collectLabels(_ node: Any, into found: inout [String]) {
        guard let object = node as? NSObject else { return }
        if let label = object.accessibilityLabel, !label.isEmpty { found.append(label) }
        for child in object.accessibilityElements ?? [] { collectLabels(child, into: &found) }
        if let view = object as? UIView {
            for subview in view.subviews { collectLabels(subview, into: &found) }
        }
    }

    /// How far the grid's scroll has been brought down, and the furthest it can be.
    private static func scrollOffset(in root: UIView) -> (offset: CGFloat, bottom: CGFloat) {
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let scroll = view as? UIScrollView {
                let bottom =
                    scroll.contentSize.height + scroll.adjustedContentInset.bottom
                    - scroll.bounds.height
                return (scroll.contentOffset.y, bottom)
            }
            stack.append(contentsOf: view.subviews)
        }
        return (0, .infinity)
    }

    /// The tallest scrollable content in the hierarchy — SwiftUI's `ScrollView` bridges to a
    /// `UIScrollView`, whose `contentSize` is what the grid actually laid out.
    private static func scrollContentHeight(in root: UIView) -> CGFloat {
        var stack: [UIView] = [root]
        var best: CGFloat = 0
        while let view = stack.popLast() {
            if let scroll = view as? UIScrollView {
                best = max(best, scroll.contentSize.height)
            }
            stack.append(contentsOf: view.subviews)
        }
        return best
    }
}

/// The landings a hosted grid reported scrolled to, in order.
@MainActor
private final class LockedLandings {
    private(set) var all: [LibraryLanding] = []
    func append(_ landing: LibraryLanding) { all.append(landing) }
}
