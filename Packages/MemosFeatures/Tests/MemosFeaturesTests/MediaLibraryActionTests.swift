import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// A stand-in for the store the viewer pages through.
///
/// It is a stand-in for a DEPENDENCY, not for the unit under test: what a real `MediaLibraryStore`
/// does with a cursor, a lineage and an `X-Next-Cursor` header is asserted against the real
/// generated client in `MediaLibraryStoreTests`, where the network can be scripted. What is
/// asserted HERE is the other half of the same wire — that the viewer asks at the right moment and that
/// asking actually reaches the store — and holding a list of a known length in front of it is the
/// only way to say "the reader is now twelve pages from the end" without a server.
@MainActor
private final class PagerProbe: MediaLibraryPaging {
    var items: [MemoAttachment]
    let pageSize: Int
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

    /// The closure the library screen hands the viewer, recorded.
    func more() async {
        loads += 1
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
    @Test("the viewer's overlay offers a library page the same actions its tile does")
    func overlayMatchesTheTile() throws {
        let page = try #require(
            MediaViewerPresentation.pages(for: [photo("a", memoUID: "m7")]).first
        )
        #expect(page.memoUID == "m7")
        #expect(
            MediaTileMenu.actions(for: page.attachment)
                == MediaTileMenu.actions(for: photo("a", memoUID: "m7"))
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
        let source = MediaViewerSource.fixed(MediaViewerPresentation.pages(for: photos(3)))
        #expect(!source.wantsMore(at: 2))
        await source.loadMore(nearing: 2)
    }

    /// Half a page ahead, measured in the store's own page size — so a store built with a different
    /// one moves the trigger with it rather than around it.
    @Test("the lookahead is half a page, and never nothing")
    func lookahead() {
        #expect(MediaViewerSource.lookahead(pageSize: 60) == 30)
        #expect(MediaViewerSource.lookahead(pageSize: 10) == 5)
        #expect(MediaViewerSource.lookahead(pageSize: 1) == 1, "a lookahead of zero never fires")
    }

    @Test("swiping to within half a page of the end reaches the store's load-more")
    func nearTheEndLoads() async {
        let pager = PagerProbe(items: photos(60))
        let source = MediaViewerSource.library(pager) { await pager.more() }

        // Page 10 of 60, with a 30-page lookahead: nowhere near.
        await source.loadMore(nearing: 10)
        #expect(pager.loads == 0, "a swipe in the middle of a loaded run asked for a page")
        #expect(pager.asked == [10], "control: the store was consulted")

        // Page 31: the first one inside the lookahead.
        await source.loadMore(nearing: 31)
        #expect(pager.loads == 1, "the next page was never asked for")
    }

    /// The store's own guard is what refuses, and the viewer asks THROUGH it rather than deciding
    /// for itself — which is what stops one flick through the end of a run from firing a request
    /// per page.
    @Test("nothing is asked for while the store says a page is already in flight")
    func inFlightBlocksASecondRequest() async {
        let pager = PagerProbe(items: photos(60))
        let source = MediaViewerSource.library(pager) { await pager.more() }

        pager.answers = false
        await source.loadMore(nearing: 59)
        #expect(pager.loads == 0, "a second page was asked for while one was in flight")
        #expect(pager.asked == [59], "control: the store really was consulted")

        pager.answers = true
        await source.loadMore(nearing: 59)
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
