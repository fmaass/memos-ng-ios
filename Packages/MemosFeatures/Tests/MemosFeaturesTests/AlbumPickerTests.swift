import Foundation
import MemosCore
@testable import MemosFeatures
import SwiftUI
import Testing

/// Add to Album's picker and its sentence (MEMNG-805): the albums it lists, the New Album path it
/// opens, the one sentence an add ends in, the select bar's button and the viewer's menu row.
@MainActor
@Suite("Album — the Add to Album picker")
struct AlbumPickerTests {
    private static func album(
        _ uid: String, kind: Trip.Kind = .album, made seconds: TimeInterval
    ) -> Trip {
        let made = Date(timeIntervalSince1970: 1_790_000_000 + seconds)
        return Trip(uid: uid, title: uid, kind: kind, createdAt: made, updatedAt: made)
    }

    private static func picture(_ uid: String, memoUID: String?) -> MemoAttachment {
        MemoAttachment(
            uid: uid, mime: "image/jpeg", status: .ready, width: 1000, height: 800,
            thumbnailURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/thumb"),
            memoUID: memoUID)
    }

    @Test("the picker lists the albums alone, newest first, the uid breaking a tie")
    func albumsNewestFirst() {
        let listed = [
            Self.album("old", made: 10), Self.album("trip", kind: .trip, made: 40),
            Self.album("new", made: 30), Self.album("tie-a", made: 20),
            Self.album("tie-b", made: 20),
        ]
        #expect(AlbumPicker.albums(listed).map(\.uid) == ["new", "tie-b", "tie-a", "old"])
        #expect(AlbumPicker.albums([]).isEmpty)
    }

    @Test("New Album opens the new-collection sheet on Album, at the album's title")
    func newAlbumPreselectsAlbum() {
        let flow = AlbumPicker.newAlbumFlow()
        #expect(flow.kind == .album, "New Album asked Trip or Album first")
        #expect(AlbumPicker.newAlbum == NewAlbumCard.title)
    }

    @Test("an add ends in one sentence: added, already there, not added and failed, summed")
    func mixedOutcomeSentence() {
        var outcome = AlbumAddOutcome(asked: 4)
        outcome.added = ["a", "b", "c"]
        outcome.alreadyMember = ["d"]
        #expect(AlbumPicker.sentence(outcome) == "3 added, 1 already there")

        var rough = AlbumAddOutcome(asked: 503)
        rough.notAdded = ["p0"]
        rough.added = (1..<500).map { "p\($0)" }
        rough.stopped = .server(status: 500)
        #expect(AlbumPicker.sentence(rough) == "499 added, 1 not added, 3 failed")
        #expect(AlbumPicker.sentence(AlbumAddOutcome(asked: 0)) == "0 added")
    }

    @Test("an add that answered nothing says why, and one that lost its session says nothing")
    func failureSentence() {
        #expect(AlbumPicker.failureSentence(.superseded) == nil)
        #expect(
            AlbumPicker.failureSentence(.busy)
                == "Another change to this album is still being saved.")
    }

    @Test("the select bar's middle is Add to Album over a selection, Select Items before one")
    func barOffersAddToAlbum() async {
        let pressed = Presses()
        let chosen = LibrarySelectToolbar(
            count: 2, ownCount: 2, isSharing: false, isDeleting: false, share: {}, delete: {},
            addToAlbum: { pressed.count += 1 })
        await CollectionsHost.with(chosen) { screen in
            let button = screen.element(labelled: AlbumPicker.title)
            #expect(button != nil, "no Add to Album over two chosen")
            #expect(button?.accessibilityValue == "2 Items Selected")
            #expect(screen.press(AlbumPicker.title), "Add to Album took no press")
            #expect(pressed.count == 1)
        }
        let none = LibrarySelectToolbar(
            count: 0, ownCount: 0, isSharing: false, isDeleting: false, share: {}, delete: {},
            addToAlbum: { pressed.count += 1 })
        await CollectionsHost.with(none) { screen in
            #expect(screen.says(LibrarySelectionPresentation.selectItems), "control: the bar stood")
            #expect(screen.element(labelled: AlbumPicker.title) == nil, "Add to Album over none")
        }
    }

    @Test("the viewer's menu offers Add to Album after Show Memo, for a picture on a memo")
    func viewerMenuEntry() {
        let onMemo = Self.picture("a", memoUID: "m7")
        #expect(
            MediaTileMenu.viewerActions(for: onMemo, albums: true)
                == [.showMemo(uid: "m7"), .addToAlbum(uid: "a")])
        #expect(
            MediaTileMenu.viewerControl(for: onMemo, albums: true)
                == .menu([.showMemo(uid: "m7"), .addToAlbum(uid: "a")]))
        // Without the album stores the row is not offered; a picture on no memo is no member.
        #expect(MediaTileMenu.viewerActions(for: onMemo) == [.showMemo(uid: "m7")])
        let orphan = Self.picture("b", memoUID: nil)
        #expect(MediaTileMenu.viewerActions(for: orphan, albums: true) == [])
        // The tile's own long press keeps its list.
        #expect(!MediaTileMenu.actions(for: onMemo).contains(.addToAlbum(uid: "a")))
        #expect(MediaTileAction.addToAlbum(uid: "a").title == AlbumPicker.title)
    }
}

/// How many times the bar's Add to Album was pressed.
@MainActor
private final class Presses {
    var count = 0
}
