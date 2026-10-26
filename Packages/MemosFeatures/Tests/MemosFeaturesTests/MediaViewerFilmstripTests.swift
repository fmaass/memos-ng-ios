import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The viewer's filmstrip (MEMNG-861): an index over the pager's reconciled pages, and the row of
/// thumbnails drawn from it.
@MainActor
@Suite("Viewer filmstrip", .serialized, .mediaGlobals)
struct MediaViewerFilmstripTests {
    init() {
        MediaImageLoader.store = MediaImageStore(
            countLimit: MediaImageLoader.countLimit,
            totalCostLimit: MediaImageLoader.totalCostLimit,
            identity: MediaIdentity()
        )
        MediaImageLoader.transport = MediaSession.shared
        MediaImageLoader.flights = MediaFetchTable()
        MediaRetrySignal.shared = MediaRetrySignal()
    }

    private static func pages(_ count: Int) -> [MediaPage] {
        MediaViewerPresentation.pages(
            for: (0..<count).map { MediaFixture.attachment(uid: "s\($0)") })
    }

    private static func viewer(_ count: Int, at start: Int) throws -> MediaViewerSelection {
        let files = (0..<count).map { MediaFixture.attachment(uid: "s\($0)") }
        return try #require(MediaViewerPresentation.viewer(for: files, startingAt: "s\(start)"))
    }

    // MARK: - the index

    @Test("the index follows the current page id across a swipe")
    func theIndexFollowsASwipe() async throws {
        let pages = Self.pages(3)
        #expect(MediaViewerIndex(pages: pages, current: "s0").position == 0)
        #expect(MediaViewerIndex(pages: pages, current: "s2").position == 2)
        #expect(MediaViewerIndex(pages: pages, current: "gone").position == nil)

        // The drawn viewer: a swipe of its pager moves the strip's current thumbnail with it.
        let opened = try Self.viewer(3, at: 0)
        let viewer = MediaViewerView(selection: opened, source: .fixed(opened.pages))
        await CollectionsHost.with(viewer) { screen in
            let drawn = await screen.until { Self.strip(in: screen.window).count == 3 }
            #expect(drawn, "the strip drew \(Self.strip(in: screen.window).count) thumbnails")
            #expect(Self.strip(in: screen.window).selected == 0, "precondition: on the first")
            guard let pager = Self.pager(in: screen.host.view) else {
                Issue.record("the viewer drew no pager")
                return
            }
            await TripProbe.page(pager, to: 1, on: screen)
            #expect(TripProbe.pageIndex(pager) == 1, "precondition: the swipe landed on page 1")
            let followed = await screen.until { Self.strip(in: screen.window).selected == 1 }
            let selected = Self.strip(in: screen.window).selected
            #expect(followed, "the strip's current is \(selected.map(String.init) ?? "none")")
        }
    }

    @Test("a delete takes the page out, shifts the index and drops the thumbnail")
    func aDeleteDropsTheThumbnail() async throws {
        let pages = Self.pages(3)
        // The source still lists s1: a memo's fixed source never shrinks. The viewer takes the
        // page out of what it adopted and keeps it in `removed`, as `remove` does.
        let outcome = MediaViewerPager.removing("s1", from: pages, current: "s2")
        let visible = MediaViewerPager.visible(shown: outcome.pages, source: pages, removed: ["s1"])
        let before = MediaViewerIndex(pages: pages, current: "s2")
        let after = MediaViewerIndex(pages: visible, current: outcome.current)
        #expect(before.position == 2)
        #expect(after.ids == ["s0", "s2"], "the index kept \(after.ids)")
        #expect(after.position == 1, "the index did not shift: \(after.position ?? -1)")

        // The drawn viewer over a fixed source that still lists the deleted page.
        let opened = try Self.viewer(3, at: 2)
        let viewer = MediaViewerView(
            selection: opened, source: .fixed(opened.pages), gone: ["s1"])
        await CollectionsHost.with(viewer) { screen in
            let dropped = await screen.until {
                let strip = Self.strip(in: screen.window)
                return strip.count == 2 && strip.selected == 1
            }
            let strip = Self.strip(in: screen.window)
            #expect(
                dropped,
                "the strip holds \(strip.count), current \(strip.selected.map(String.init) ?? "none")"
            )
        }
    }

    @Test("pages the library appends extend the strip and leave the current thumbnail where it is")
    func growthExtendsTheStrip() {
        let loaded = Self.pages(4)
        let grown = Self.pages(12)
        let width: CGFloat = 402
        let before = MediaViewerIndex(pages: loaded, current: "s3")
        let after = MediaViewerIndex(
            pages: MediaViewerPager.visible(shown: loaded, source: grown, removed: []),
            current: "s3")
        #expect(after.ids == grown.map(\.id), "the index over the grown list: \(after.ids)")
        #expect(after.position == before.position, "the current page moved in the index")

        // Where the current thumbnail sits on screen: the middle, whatever the count.
        func centre(_ index: MediaViewerIndex) -> CGFloat {
            let position = index.position ?? 0
            return MediaViewerFilmstrip.rowOffset(width: width, anchor: position, translation: 0)
                + MediaViewerFilmstrip.leading(of: position, current: position)
                + MediaViewerFilmstrip.currentWidth / 2
        }
        #expect(centre(before) == width / 2)
        #expect(centre(after) == centre(before), "the current thumbnail moved when pages arrived")

        let built = MediaViewerFilmstrip.window(count: loaded.count, around: 3, width: width)
        let extended = MediaViewerFilmstrip.window(count: grown.count, around: 3, width: width)
        #expect(built == 0..<4)
        #expect(extended.contains(4) && extended.contains(9), "the strip stops at \(extended)")
    }

    @Test("a drag maps its offset to a page monotonically, and never past either end")
    func scrubIsMonotonic() {
        let pitch = MediaViewerFilmstrip.pitch
        for (start, count) in [(0, 10), (5, 10), (9, 10), (0, 1)] {
            var last = Int.max
            for step in -600...600 {
                let page = MediaViewerFilmstrip.scrubbed(
                    from: start, translation: CGFloat(step) / 2, count: count)
                #expect((0..<count).contains(page), "offset \(step / 2) reached page \(page)")
                #expect(page <= last, "start \(start): offset \(step / 2) went back to \(page)")
                last = page
            }
            #expect(
                MediaViewerFilmstrip.scrubbed(from: start, translation: 0, count: count) == start)
        }
        #expect(MediaViewerFilmstrip.scrubbed(from: 5, translation: -pitch, count: 10) == 6)
        #expect(MediaViewerFilmstrip.scrubbed(from: 5, translation: pitch * 2, count: 10) == 3)
        #expect(MediaViewerFilmstrip.scrubbed(from: 5, translation: -pitch * 40, count: 10) == 9)
    }

    @Test("a delete landing mid-drag keeps the scrub on the page it began on")
    func aDeleteMidDragDoesNotJump() throws {
        let pitch = MediaViewerFilmstrip.pitch
        let ten = (0..<10).map { "s\($0)" }
        func page(_ ids: [MediaPage.ID], _ step: (scrub: FilmstripScrub, reached: Int)) -> String {
            ids[step.reached]
        }

        // The finger goes down on s5 and moves one page on.
        let first = MediaViewerFilmstrip.dragged(nil, to: -pitch, over: ten, current: 5)
        #expect(page(ten, first) == "s6")

        // s1 is deleted under the finger: every later page moves one place down.
        let nine = ten.filter { $0 != "s1" }
        let current = try #require(nine.firstIndex(of: "s6"))
        let second = MediaViewerFilmstrip.dragged(
            first.scrub, to: -pitch * 2, over: nine, current: current)
        #expect(page(nine, second) == "s7", "two pages on from s5 is s7, not \(page(nine, second))")

        // The anchor itself is deleted: the scrub starts again from the page on screen, at the
        // finger's present travel, and the next page on is the one after it.
        let gone = nine.filter { $0 != "s5" }
        let onScreen = try #require(gone.firstIndex(of: "s7"))
        let rebased = MediaViewerFilmstrip.dragged(
            second.scrub, to: -pitch * 2, over: gone, current: onScreen)
        #expect(page(gone, rebased) == "s7", "the anchor's delete moved the strip")
        let onward = MediaViewerFilmstrip.dragged(
            rebased.scrub, to: -pitch * 3, over: gone, current: onScreen)
        #expect(page(gone, onward) == "s8")

        // Control: with nothing deleted, the same travel from s5 reaches s7.
        let still = MediaViewerFilmstrip.dragged(first.scrub, to: -pitch * 2, over: ten, current: 6)
        #expect(page(ten, still) == "s7")
    }

    @Test("the strip hides with the chrome")
    func theStripHidesWithTheChrome() async {
        var chrome = MediaViewerChrome()
        #expect(chrome.shown.contains(.filmstrip))
        chrome.tapped()
        #expect(!chrome.shown.contains(.filmstrip), "a tap left the strip up")

        let pages = Self.pages(3)
        for shown in [true, false] {
            let strip = MediaViewerFilmstrip(
                pages: pages, current: "s0", shown: shown, select: { _ in })
            await CollectionsHost.with(strip) { screen in
                // The shown strip is the control: the same read finds its three thumbnails.
                let settled = await screen.until { Self.strip(in: screen.window).count == 3 }
                let count = Self.strip(in: screen.window).count
                if shown {
                    #expect(settled, "control: the strip drew \(count) thumbnails")
                } else {
                    #expect(count == 0, "the hidden strip still offers \(count) thumbnails")
                }
            }
        }
    }

    /// Double-tapped to zoom, a picture holds the pager and the interactive dismissal; the strip
    /// then turns the pager without a swipe, and the picture it left never reports a release.
    @Test("a zoom hold on one page does not hold the page the strip goes to")
    func stripNavigationReleasesTheHold() {
        let pages = Self.pages(3)
        let magnified: MediaPage.ID = "s0"
        #expect(
            MediaViewerPager.stands(magnified, among: pages, current: "s0"),
            "control: the magnified page on screen holds")
        // A tap on s1's thumbnail, or a scrub passing it: the viewer's page is now s1.
        #expect(
            !MediaViewerPager.stands(magnified, among: pages, current: "s1"),
            "s1 cannot be swiped or dismissed: s0's zoom hold still stands")
        #expect(
            MediaViewerPager.stands(magnified, among: pages, current: "s0"),
            "back on s0, still magnified, the hold no longer stands")
    }

    /// Zoom s0, tap a far thumbnail, browse there, come back: the lazy pager dropped s0's view on
    /// the way and builds it again, unzoomed. That new page has to say so, or the hold the dropped
    /// one took would still stand on a picture that is no longer magnified.
    @Test("a page the pager built again comes back without the hold its old view took")
    func aRebuiltPageComesBackUnheld() async {
        let pages = Self.pages(3)
        let viewer = HoldsBox()
        viewer.holds.report(MediaZoom.Holds(pager: true, dismissal: true), by: "s0")
        #expect(
            viewer.holds.holdsPager(among: pages, current: "s0")
                && viewer.holds.holdsDismissal(among: pages, current: "s0"),
            "control: magnified s0 on screen holds both")

        // The rebuilt s0, wired to the viewer's holds exactly as the pager wires each page.
        let page = pages[0]
        let rebuilt = MediaViewerPage(
            page: page, onHoldsChange: { viewer.holds.report($0, by: page.id) },
            player: nil, play: {})
        await CollectionsHost.with(rebuilt) { screen in
            let released = await screen.until {
                !viewer.holds.holdsPager(among: pages, current: "s0")
                    && !viewer.holds.holdsDismissal(among: pages, current: "s0")
            }
            #expect(released, "the unzoomed s0 still holds the pager or the dismissal")
        }
    }

    /// Zoom s0, tap s1 on the strip, zoom s1, tap s0: s0 is still magnified and has reported
    /// nothing since, so its hold has to have survived s1 taking one of its own.
    @Test("a magnified page gone back to still holds after another page took a hold")
    func aMagnifiedPageKeepsItsHold() {
        let pages = Self.pages(3)
        var holds = MediaViewerHolds()
        holds.report(MediaZoom.Holds(pager: true, dismissal: true), by: "s0")
        holds.report(MediaZoom.Holds(pager: true, dismissal: true), by: "s1")
        #expect(
            holds.holdsPager(among: pages, current: "s1")
                && holds.holdsDismissal(among: pages, current: "s1"),
            "control: magnified s1 on screen holds both")
        #expect(
            holds.holdsPager(among: pages, current: "s0"),
            "back on magnified s0, the pager swipes")
        #expect(
            holds.holdsDismissal(among: pages, current: "s0"),
            "back on magnified s0, the presentation dismisses")
        // s1 released, s0 untouched: only s1's own report takes s1 out.
        holds.report(MediaZoom.Holds(pager: false, dismissal: false), by: "s1")
        #expect(!holds.holdsPager(among: pages, current: "s1"), "s1's release did not take")
        #expect(holds.holdsPager(among: pages, current: "s0"), "s1's release took s0's hold")
        #expect(!holds.holdsPager(among: pages, current: "s2"), "s2 never held")
    }

    // MARK: - probes

    /// The viewer's pager: the widest horizontal scroll view under `root`.
    private static func pager(in root: UIView) -> UIScrollView? {
        var stack: [UIView] = [root]
        var best: UIScrollView?
        while let view = stack.popLast() {
            if let scroller = view as? UIScrollView, scroller.window != nil,
                scroller.bounds.width > 0,
                scroller.contentSize.width > scroller.bounds.width * 1.5,
                scroller.contentSize.width > (best?.contentSize.width ?? 0)
            {
                best = scroller
            }
            stack.append(contentsOf: view.subviews)
        }
        return best
    }

    /// The strip as the screen exposes it: how many thumbnails, and which of them, left to right,
    /// is the selected one.
    private static func strip(in window: UIWindow) -> (count: Int, selected: Int?) {
        window.layoutIfNeeded()
        var seen: Set<ObjectIdentifier> = []
        var found: [(x: CGFloat, selected: Bool)] = []
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            if let element = node as? NSObject {
                guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
                if let label = element.accessibilityLabel, label.hasSuffix(" thumbnail") {
                    found.append(
                        (
                            element.accessibilityFrame.minX,
                            element.accessibilityTraits.contains(.selected)
                        ))
                }
                if let children = element.accessibilityElements {
                    stack.append(contentsOf: children)
                }
            }
            if let view = node as? UIView { stack.append(contentsOf: view.subviews) }
        }
        let ordered = found.sorted { $0.x < $1.x }
        return (ordered.count, ordered.firstIndex { $0.selected })
    }
}

/// The viewer's holds, shared by reference with a hosted page's report closure.
@MainActor
private final class HoldsBox {
    var holds = MediaViewerHolds()
}
