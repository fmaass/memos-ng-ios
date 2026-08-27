import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// A stand-in for the store the viewer pages through.
///
/// It is a stand-in for a DEPENDENCY, not for the unit under test: what a real `MediaLibraryStore`
/// does with a cursor, a lineage and an `X-Next-Cursor` header is asserted against the real
/// generated client in `MediaLibraryStoreTests`, where the network can be scripted. What is
/// asserted HERE is the other half of the same wire — that the viewer asks at the right moment,
/// and that asking actually reaches the store — and holding a list of a known length in front of
/// it is the only way to say "the reader is now twelve rows from the end" without a server.
@MainActor
private final class PagerProbe: MediaLibraryPaging {
    var items: [MemoAttachment]
    let pageSize: Int
    var hasMore = true
    /// What the real store's own guard answers. Set false to stand for "a page is already in
    /// flight" or "this list has ended".
    var answers = true
    /// Every index the viewer asked about, in order.
    private(set) var asked: [Int] = []
    private(set) var loads = 0

    init(items: [MemoAttachment], pageSize: Int = 60) {
        self.items = items
        self.pageSize = pageSize
    }

    func shouldLoadMore(after index: Int, lookahead: Int) -> Bool {
        asked.append(index)
        guard answers else { return false }
        return index >= items.count - lookahead
    }

    /// Pages the server will hand back, in order — one per `more()`. Empty means the list ends.
    var script: [[MemoAttachment]] = []

    /// The closure the library screen hands the viewer, recorded — and, unlike a bare counter, it
    /// actually MOVES the list, which is what lets a run of pages that show nothing be driven.
    func more() async {
        loads += 1
        guard !script.isEmpty else {
            hasMore = false
            return
        }
        items += script.removeFirst()
        hasMore = !script.isEmpty
    }
}

@MainActor
private func photo(_ uid: String, memoUID: String? = nil) -> MemoAttachment {
    MemoAttachment(
        uid: uid,
        mime: "image/jpeg",
        status: .ready,
        width: 1000,
        height: 800,
        thumbnailURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/thumb"),
        previewURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/mobile"),
        webURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/web"),
        memoUID: memoUID
    )
}

@MainActor
private func photos(_ count: Int, from: Int = 0) -> [MemoAttachment] {
    (from..<(from + count)).map { photo("p\($0)") }
}

/// A page of nothing this viewer can show.
@MainActor
private func documents(_ count: Int, from: Int) -> [MemoAttachment] {
    (from..<(from + count)).map {
        MemoAttachment(uid: "d\($0)", mime: "application/pdf", status: .ready)
    }
}

/// Library rows as they really arrive: pictures with documents among them. Every third row is a
/// PDF, which the viewer drops — which is exactly why a page offset is not a row index.
@MainActor
private func mixedRows(_ count: Int) -> [MemoAttachment] {
    (0..<count).map { index in
        index % 3 == 2
            ? MemoAttachment(uid: "d\(index)", mime: "application/pdf", status: .ready)
            : photo("p\(index)")
    }
}

/// What a long press on a tile — and the viewer over the same file — offers.
@MainActor
@Suite("Library actions")
struct MediaTileMenuTests {
    @Test("a file that belongs to a memo can be taken to it; an orphan cannot")
    func ownedAndOrphan() {
        let owned = MediaTileMenu.actions(for: photo("a", memoUID: "m7"))
        #expect(owned.first == .showMemo(uid: "m7"), "the owner did not reach the menu")

        let orphan = MediaTileMenu.actions(for: photo("b"))
        let offersAMemo = orphan.contains { action in
            if case .showMemo = action { return true }
            return false
        }
        #expect(!offersAMemo, "an orphan was offered a memo it does not have")
        // The control: the orphan still gets a menu, so the absence above is about the OWNER and
        // not about an empty action list.
        #expect(orphan.count == 1)
    }

    /// Two files, two shapes of menu, and the order is the order they are shown in.
    @Test("Show Memo comes first and Share follows it")
    func order() {
        #expect(
            MediaTileMenu.actions(for: photo("a", memoUID: "m7")).map(\.title)
                == ["Show Memo", "Share"]
        )
    }

    @Test("a file with no canonical URL is not offered a share that would share nothing")
    func nothingToShare() {
        var bare = photo("a", memoUID: "m7")
        bare.webURL = nil
        #expect(MediaTileMenu.actions(for: bare) == [.showMemo(uid: "m7")])
    }

    /// The viewer's overlay is built from the same list, over the page's own attachment — which is
    /// what stops the two surfaces from offering different things about one file.
    /// The expectation is written out by hand rather than taken from the function being tested —
    /// comparing `actions(for:)` to `actions(for:)` asserts only that it is deterministic.
    @Test("the viewer's overlay offers a library page exactly Show Memo then Share")
    func overlayOffersTheWholeActionSet() throws {
        let attachment = photo("a", memoUID: "m7")
        let page = try #require(MediaViewerPresentation.pages(for: [attachment]).first)
        let webURL = try #require(attachment.webURL)

        #expect(page.memoUID == "m7")
        #expect(
            MediaTileMenu.actions(for: page.attachment)
                == [.showMemo(uid: "m7"), .share(webURL)]
        )
    }

    /// A memo's OWN media carries no owner, so the viewer opened from a memo offers no way back to
    /// the screen it was opened from.
    @Test("a memo's own attachment is offered no Show Memo")
    func memoSourcedAttachmentHasNoOwner() {
        #expect(MediaTileMenu.actions(for: photo("a")) == [.share(photo("a").webURL!)])
    }
}

/// MEMNG-189: the viewer continues the grid's cursor.
@MainActor
@Suite("Viewer paging")
struct MediaViewerPagingTests {
    @Test("a memo's viewer never asks for more, because there is no more")
    func fixedSourceNeverPages() async {
        let pages = MediaViewerPresentation.pages(for: photos(3))
        let source = MediaViewerSource.fixed(pages)
        #expect(!source.wantsMore(atPageWithID: pages[2].id))
        #expect(!source.hasMore)
        await source.loadMore(nearingPageWithID: pages[2].id)
    }

    /// Half a page ahead, measured in the store's own page size — so a store built with a different
    /// one moves the trigger with it rather than around it.
    @Test("the lookahead is half a page, and never nothing")
    func lookahead() {
        #expect(MediaViewerSource.lookahead(pageSize: 60) == 30)
        #expect(MediaViewerSource.lookahead(pageSize: 10) == 5)
        #expect(MediaViewerSource.lookahead(pageSize: 1) == 1, "a lookahead of zero never fires")
    }

    /// The rows are MIXED: every third one is a PDF, which the viewer drops. So the page a reader
    /// is standing on sits far later in the store than in the pager, and the near-end rule has to
    /// be measured where the store measures it. Handing the projected offset over instead reads as
    /// 20 rows earlier here, which is inside the lookahead and never fires.
    @Test("the near-end trigger is measured against the store's own rows, not the viewer's pages")
    func nearTheEndUsesRawRows() async {
        let pager = PagerProbe(items: mixedRows(60))
        let source = MediaViewerSource.library(pager) { await pager.more() }
        let deep = pager.items[31].uid
        let shallow = pager.items[29].uid
        // The projection really does renumber: this is what makes the two indices different.
        let projected = MediaViewerPresentation.pages(for: pager.items).map(\.id)
        #expect(projected.count < pager.items.count, "control: documents were dropped")
        #expect(projected.firstIndex(of: deep) != 31, "control: page offset differs from row index")

        await source.loadMore(nearingPageWithID: shallow)
        #expect(pager.loads == 0, "a swipe in the middle of a loaded run asked for a page")
        #expect(pager.asked == [29], "control: the store was consulted, with the ROW index")

        await source.loadMore(nearingPageWithID: deep)
        #expect(pager.loads == 1, "the next page was never asked for")
        #expect(pager.asked == [29, 31], "the store was asked about the wrong index")
    }

    /// The dead end this seam exists to remove. Two consecutive pages of documents grow the
    /// store's rows and leave the viewer's projection exactly as long as it was — so nothing the
    /// SCREEN can observe changes, and by the time a second ask could be made the raw list has
    /// grown past the near-end guard. One swipe therefore has to read through to the next picture
    /// by itself.
    @Test("a run of pages with nothing to show is read through to the next picture, in one ask")
    func documentsOnlyPagesAreReadThrough() async {
        let pager = PagerProbe(items: photos(60))
        pager.script = [
            documents(5, from: 100),
            documents(5, from: 200),
            [photo("after-the-paperwork")],
        ]
        let source = MediaViewerSource.library(pager) { await pager.more() }
        let before = source.pages.count

        await source.loadMore(nearingPageWithID: pager.items[59].uid)

        #expect(pager.loads == 3, "the blank pages were not read through")
        #expect(source.pages.count == before + 1, "the picture past the documents never arrived")
        #expect(
            source.pages.map(\.id).contains("after-the-paperwork"),
            "the viewer dead-ended on a run of documents"
        )
    }

    /// Bounded, because the tail of a library can be any length of documents and one swipe must
    /// not set a request loop running that only the end of the list can stop.
    @Test("reading through pages that show nothing stops at the bound")
    func readingThroughIsBounded() async {
        let pager = PagerProbe(items: photos(60))
        pager.script = (0..<50).map { documents(2, from: 1000 + $0 * 2) }
        let source = MediaViewerSource.library(pager) { await pager.more() }

        await source.loadMore(nearingPageWithID: pager.items[59].uid)

        #expect(pager.loads == MediaViewerSource.maximumBlankContinuations)
        #expect(pager.hasMore, "control: the list had not ended, so the bound is what stopped it")
    }

    /// The wire the library screen owns: the viewer must read the very store the grid is reading.
    @Test("the library screen hands the viewer its own live store")
    func libraryScreenWiresTheRealStore() async {
        let store = MediaLibraryStore(pageSize: 60)
        let source = MediaLibraryView.viewerSource(for: store) {}
        guard case .library(let wired, _) = source else {
            Issue.record("the library screen handed the viewer a fixed snapshot")
            return
        }
        #expect(wired === store, "the viewer pages through a copy, not the grid's own store")
        #expect(MediaLibraryView.viewerSource(for: nil) {}.hasMore == false)
    }

    /// The store's own guard is what refuses, and the viewer asks THROUGH it rather than deciding
    /// for itself — which is what stops one flick through the end of a run from firing a request
    /// per page.
    @Test("nothing is asked for while the store says a page is already in flight")
    func inFlightBlocksASecondRequest() async {
        let pager = PagerProbe(items: photos(60))
        let source = MediaViewerSource.library(pager) { await pager.more() }

        let last = pager.items[59].uid
        pager.answers = false
        await source.loadMore(nearingPageWithID: last)
        #expect(pager.loads == 0, "a second page was asked for while one was in flight")
        #expect(pager.asked == [59], "control: the store really was consulted")

        pager.answers = true
        await source.loadMore(nearingPageWithID: last)
        #expect(pager.loads == 1, "control: the same swipe loads once the store says yes")
    }

    @Test("the viewer's pages are the store's rows, projected")
    func sourcePagesFollowTheStore() {
        let pager = PagerProbe(items: photos(3))
        let source = MediaViewerSource.library(pager) { await pager.more() }
        #expect(source.pages.map(\.id) == ["p0", "p1", "p2"])

        pager.items = photos(5)
        #expect(source.pages.map(\.id) == ["p0", "p1", "p2", "p3", "p4"])
    }
}

/// What an open viewer does when the list behind it changes.
@MainActor
@Suite("Viewer page adoption")
struct MediaViewerPagerTests {
    private func pages(_ uids: [String]) -> [MediaPage] {
        MediaViewerPresentation.pages(for: uids.map { photo($0) })
    }

    @Test("an appended page extends the viewer in place")
    func appendIsAdopted() {
        let shown = pages(["p0", "p1"])
        let grown = pages(["p0", "p1", "p2"])
        let extended = MediaViewerPager.extended(shown, with: grown)

        #expect(extended.map(\.id) == ["p0", "p1", "p2"])
        // The reader's page is tracked by identity, so "the index did not move" is exactly this:
        // every id that was there is still at the offset it was at.
        #expect(extended.firstIndex { $0.id == "p1" } == shown.firstIndex { $0.id == "p1" })
    }

    /// The three ways the grid can pull the rug out: a tab change (empties it), a sort change
    /// (reverses it) and a refresh that replaced the head. None of them is something the reader
    /// asked THIS viewer for, and none of them may take the open pages away.
    @Test("a list that is no longer the same list leaves the open pages alone")
    func replacementIsIgnored() {
        let shown = pages(["p0", "p1", "p2"])

        #expect(MediaViewerPager.extended(shown, with: []).map(\.id) == ["p0", "p1", "p2"])
        #expect(
            MediaViewerPager.extended(shown, with: pages(["p2", "p1", "p0"])).map(\.id)
                == ["p0", "p1", "p2"],
            "a reversed library replaced the pages under an open viewer"
        )
        #expect(
            MediaViewerPager.extended(shown, with: pages(["q0", "q1", "q2", "q3"])).map(\.id)
                == ["p0", "p1", "p2"],
            "a different list of the same length was adopted"
        )
        // A shorter list cannot be this list plus more, whatever it begins with.
        #expect(MediaViewerPager.extended(shown, with: pages(["p0", "p1"])).map(\.id).count == 3)
    }

    /// The race the viewer used to lose: the grid finished a page between the tap and the cover's
    /// first frame, so the longer list was never an `onChange` — it simply WAS the baseline. The
    /// rendered pages are reconciled on every evaluation, which is this computation.
    @Test("pages the grid loaded before the first frame are adopted, not lost")
    func pagesLoadedBeforeFirstRenderAreAdopted() {
        let opened = pages(["p0", "p1"])
        let pager = PagerProbe(items: photos(5))
        let source = MediaViewerSource.library(pager) {}

        let rendered = MediaViewerPager.extended(opened, with: source.pages)
        #expect(rendered.map(\.id) == ["p0", "p1", "p2", "p3", "p4"])
        #expect(rendered.count > opened.count, "the first frame showed the stale snapshot")
    }

    @Test("an unchanged list changes nothing")
    func sameListIsStable() {
        let shown = pages(["p0", "p1"])
        #expect(MediaViewerPager.extended(shown, with: shown) == shown)
    }
}

/// MEMNG-189: what a page says out loud, now that the list it is in can grow.
@MainActor
@Suite("Viewer page labels")
struct MediaViewerLabelTests {
    @Test("a page describes what it is and never how many there are")
    func noCountAnywhere() {
        let pages = MediaViewerPresentation.pages(for: [
            photo("a"),
            MemoAttachment(
                uid: "v",
                mime: "video/mp4",
                status: .ready,
                posterURL: URL(string: "https://memos.example.invalid/api/attachments/v/poster")
            ),
        ])
        #expect(pages.map(\.accessibilityLabel) == ["Photo", "Video"])
        // A count read from a list still being paged would be read out wrong; the numbers are
        // gone from the model, not merely unprinted.
        #expect(pages.allSatisfy { !$0.accessibilityLabel.contains("of") })
    }
}

/// MEMNG-191: a memo asked for from a tab that cannot open one.
@MainActor
@Suite("Jump to memo")
struct MemoJumpTests {
    @Test("asking carries the memo, and it stays pending until somebody takes it")
    func requestCarriesTheUID() {
        let jump = MemoJump()
        #expect(jump.pending == nil)

        jump.request("m7")
        #expect(jump.pending == "m7")

        jump.clear()
        #expect(jump.pending == nil)
    }

    @Test("a pending request puts the app on the Timeline, whatever tab it was on")
    func routerSwitchesTabs() {
        #expect(MemoJumpRouting.tab(showing: .library, whenJumping: "m7") == .timeline)
        #expect(MemoJumpRouting.tab(showing: .timeline, whenJumping: "m7") == .timeline)
        // Nothing pending is not an instruction to go anywhere: switching tabs by hand must not be
        // undone a frame later.
        #expect(MemoJumpRouting.tab(showing: .library, whenJumping: nil) == .library)
    }

    /// The case that is NORMAL here rather than an edge: the library is ordered by file and the
    /// timeline by memo, so a photograph a few screens down the grid routinely belongs to a memo
    /// this list has never loaded.
    @Test("a memo outside the loaded window is read before it is pushed")
    func notLoadedIsFetched() {
        #expect(MemoJumpRouting.resolution(uid: "m7", loaded: ["m1", "m2"]) == .fetchThenPush)
        #expect(MemoJumpRouting.resolution(uid: "m7", loaded: []) == .fetchThenPush)
        #expect(MemoJumpRouting.resolution(uid: "m7", loaded: ["m7"]) == .push)
    }

    /// The action a tile offers and the request the router consumes are one wire, and this is the
    /// join: the uid in the menu is the uid that ends up pending.
    @Test("the tile's Show Memo is what the router acts on")
    func tileActionFeedsTheRouter() throws {
        let actions = MediaTileMenu.actions(for: photo("a", memoUID: "m7"))
        let jump = MemoJump()
        for action in actions {
            if case .showMemo(let uid) = action { jump.request(uid) }
        }
        let uid = try #require(jump.pending)
        #expect(uid == "m7")
        #expect(MemoJumpRouting.tab(showing: .library, whenJumping: uid) == .timeline)
        #expect(MemoJumpRouting.resolution(uid: uid, loaded: ["m1"]) == .fetchThenPush)
    }
}

/// MEMNG-190: the chosen direction, across launches.
@MainActor
@Suite("Library sort preference")
struct LibraryPreferencesTests {
    private func scratch() -> (defaults: UserDefaults, name: String) {
        let name = "memosng.library.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("a device that has never chosen reads newest-first")
    func defaultIsNewestFirst() {
        let (defaults, name) = scratch()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        #expect(LibraryPreferences(defaults: defaults).order == .newestFirst)
    }

    @Test("a chosen direction survives the next launch")
    func roundTrip() {
        let (defaults, name) = scratch()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let chosen = LibraryPreferences(defaults: defaults)
        chosen.select(.oldestFirst)
        #expect(chosen.order == .oldestFirst)

        // A second store over the SAME suite is what the next launch is.
        #expect(LibraryPreferences(defaults: defaults).order == .oldestFirst)
        #expect(defaults.string(forKey: LibraryPreferences.orderKey) == "oldestFirst")
    }

    /// A settings key is read on every launch forever, so a value written by a version that knew a
    /// direction this one does not must read as the default rather than crash or stick.
    @Test("a value this version does not know reads as the default")
    func unknownStoredValue() {
        #expect(LibraryPreferences.order(fromStored: nil) == .newestFirst)
        #expect(LibraryPreferences.order(fromStored: "") == .newestFirst)
        #expect(LibraryPreferences.order(fromStored: "byColour") == .newestFirst)
        // The control: the two it DOES know are read back, so the default above is a decision
        // rather than a reader that always answers the same thing.
        #expect(LibraryPreferences.order(fromStored: "oldestFirst") == .oldestFirst)
        #expect(LibraryPreferences.order(fromStored: "newestFirst") == .newestFirst)
    }

    /// The menu's two rows and what each of them asks the server for.
    @Test("both directions are offered, under Photos' own words")
    func menuRows() {
        #expect(MediaLibraryOrder.allCases.map(\.label) == ["Newest First", "Oldest First"])
        #expect(MediaLibraryOrder.newestFirst.apiOrder == "desc")
        #expect(MediaLibraryOrder.oldestFirst.apiOrder == "asc")
    }
}
