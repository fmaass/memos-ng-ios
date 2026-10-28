import Foundation
import MemosOutbox
import Testing

@testable import MemosCore

/// The pending cards a timeline draws above its memos (MEMNG-951).
@Suite("Pending memo cards")
struct PendingMemoBoardTests {
    private static let binding = AccountBinding(
        serverBaseURL: URL(string: "https://memos.example.invalid")!, ownerSubject: "fabian")

    private func job(
        _ content: String = "at the #beach with #friends #beach",
        at seconds: TimeInterval = 1_750_000_000,
        files: Int = 2
    ) -> UploadJob {
        UploadJob(
            content: content,
            capturedAt: Date(timeIntervalSince1970: seconds),
            files: (0..<files).map { index in
                OutboxFile(
                    relativePath: "f\(index).heic", filename: "IMG_\(index).HEIC",
                    mime: "image/heic", byteSize: 100)
            },
            binding: Self.binding
        )
    }

    @Test("a queued capture is a card with its words, date, tags and one tile per file")
    func cardCarriesTheCapture() {
        var board = PendingMemoBoard()
        let capture = job()
        board.show([capture], resolved: [:])
        let card = board.visible(present: []).first
        #expect(card?.id == PendingMemoBoard.key(for: capture.id))
        #expect(card?.caption == capture.content)
        #expect(card?.date == capture.capturedAt)
        #expect(card?.tags == ["beach", "friends"])
        #expect(card?.tiles.map(\.id) == capture.files.map(\.id))
    }

    @Test("the newest capture is on top, and one taken back to the editor is not a card")
    func orderAndCancelled() {
        var board = PendingMemoBoard()
        let older = job(at: 1_000)
        let newer = job(at: 2_000)
        var taken = job(at: 3_000)
        taken.cancelledAt = Date()
        board.show([older, taken, newer], resolved: [:])
        #expect(board.visible(present: []).map(\.job.id) == [newer.id, older.id])
    }

    @Test("the memo a card became is drawn under the card's own key, so the swap does not jump")
    func memoKeepsTheCardsKey() {
        var board = PendingMemoBoard()
        let capture = job()
        board.show([capture], resolved: [:])
        let key = board.visible(present: []).first?.id
        // The create answered and the job left the queue; the list has not been read yet.
        board.show([], resolved: [capture.id: "m1"])
        #expect(board.visible(present: []).map(\.id) == [key])
        // The list now holds the memo: the card IS that memo, under the same key.
        #expect(board.visible(present: ["m1"]).isEmpty)
        #expect(board.key(for: "m1") == key)
        board.settle()
        #expect(board.key(for: "m1") == key)
        // A memo that never was a card keeps its own uid.
        #expect(board.key(for: "m2") == "m2")
    }

    @Test("a removed card is not resurrected by a create answer or a read that outlived it")
    func withdrawalIsFenced() {
        var board = PendingMemoBoard()
        let capture = job()
        board.show([capture], resolved: [:])
        board.withdraw(capture.id)
        #expect(board.visible(present: []).isEmpty)
        // A read of the queue that began before the removal still lists it.
        board.show([capture], resolved: [:])
        #expect(board.visible(present: []).isEmpty)
        // A create answer that outlived the removal names the memo it made.
        board.show([], resolved: [capture.id: "m1"])
        #expect(board.visible(present: []).isEmpty)
        #expect(board.key(for: "m1") == "m1")
    }

    @Test("a card whose capture left the queue without becoming a memo is gone")
    func vanishedCaptureLeaves() {
        var board = PendingMemoBoard()
        board.show([job()], resolved: [:])
        board.show([], resolved: [:])
        #expect(board.visible(present: []).isEmpty)
    }

    @Test("a capture whose create was in flight when it was edited shows the edit")
    func pendingEditIsWhatTheCardSays() {
        var capture = job("before")
        capture.pendingEdit = PendingEdit(
            content: "after #now", visibility: nil, capturedAt: Date(timeIntervalSince1970: 5),
            fileIDs: [capture.files[1].id])
        var board = PendingMemoBoard()
        board.show([capture], resolved: [:])
        let card = board.visible(present: []).first
        #expect(card?.caption == "after #now")
        #expect(card?.tags == ["now"])
        #expect(card?.date == Date(timeIntervalSince1970: 5))
        #expect(card?.tiles.map(\.id) == [capture.files[1].id])
    }

    @MainActor
    @Test("the timeline shows only the signed-in account's captures, and forgets them on clear")
    func timelineShowsOnlyThisAccountsCaptures() {
        let store = TimelineStore()
        let mine = job()
        var theirs = job()
        theirs.binding = AccountBinding(
            serverBaseURL: Self.binding.serverBaseURL, ownerSubject: "someone-else")
        let identity = TimelineSnapshotIdentity(
            server: Self.binding.serverBaseURL, subject: Self.binding.ownerSubject)
        store.showPending([mine, theirs], resolved: [:], for: identity)
        #expect(store.pendingCards.map(\.job.id) == [mine.id])
        store.showPending([mine], resolved: [:], for: nil)
        #expect(store.pendingCards.isEmpty)

        store.showPending([mine], resolved: [:], for: identity)
        store.withdrawPending(mine.id)
        store.showPending([mine], resolved: [mine.id: "m1"], for: identity)
        #expect(store.pendingCards.isEmpty)
        #expect(store.identityKey(forUID: "m1") == "m1")
        store.clearRows()
        // A cleared timeline is a new board: the removal was about the account that left.
        store.showPending([mine], resolved: [:], for: identity)
        #expect(store.pendingCards.map(\.job.id) == [mine.id])
    }
}
