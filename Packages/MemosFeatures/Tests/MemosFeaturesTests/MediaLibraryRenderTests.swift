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
        let items: [MemoAttachment]
        @Namespace private var zoom

        var body: some View {
            LibraryGrid(
                items: items,
                errorText: nil,
                loadingMore: false,
                zoom: zoom,
                wantsMore: { _ in false },
                open: { _ in },
                save: { _ in },
                loadMore: {}
            )
        }
    }

    /// The library the defect shipped against, in miniature: photographs in their own shapes, a
    /// clip, and a file with no dimensions at all (a migrated original the server never measured).
    private static let items: [MemoAttachment] = [
        MediaViewerPageTests.image("lib-a", width: 4000, height: 3000),
        MediaViewerPageTests.image("lib-b", width: 3000, height: 4000),
        MediaViewerPageTests.image("lib-c", width: 8192, height: 2048),
        MediaViewerPageTests.image("lib-d", width: 2000, height: 2000),
        MediaViewerPageTests.video("lib-e"),
        MediaViewerPageTests.image("lib-f", width: 4032, height: 3024),
        MediaViewerPageTests.other("lib-g", mime: "application/pdf"),
        MediaViewerPageTests.image("lib-h", width: 2448, height: 3264),
    ]

    @Test("a grid holding files places them once it has a real frame")
    func gridPlacesTilesInARealFrame() async throws {
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(rootView: Harness(items: Self.items))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // What the solver itself packs for the width the grid must derive: the window's 390,
        // less the grid's own horizontal padding either side. The grid draws that packing as a
        // scroll whose content is the rows, their gaps and the stack's vertical padding — so the
        // content height IS the placement, readable from outside the hierarchy.
        let gap = DesignTokens.Space.tight
        let solved = MediaLibraryPresentation.rows(
            for: Self.items, width: Double(390 - 2 * gap), gap: Double(gap))
        #expect(!solved.isEmpty, "the fixture must solve to rows — otherwise this asserts nothing")
        let expected =
            solved.reduce(CGFloat(0)) { $0 + CGFloat($1.height) }
            + CGFloat(solved.count - 1) * gap + 2 * gap

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
