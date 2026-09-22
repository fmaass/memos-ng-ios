import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The order the row puts the memo's own pictures in, and the list a save states about them.
///
/// Both are pure functions on purpose. The order is a fact about dates and the list is a fact
/// about which half of the row each tile is in, and neither needs a screen to be asked — so the
/// cases that matter are the ones a hosted test would reach only by accident: an instant missing,
/// two instants equal, a tile whose file never arrived.
@Suite("The compose row's order and the list a save states")
struct ComposePictureListTests {
    private func attachment(_ uid: String, taken: Date? = nil) -> MemoAttachment {
        MemoAttachment(uid: uid, mime: "image/jpeg", status: .ready, captureInstant: taken)
    }

    private func existing(_ uid: String, taken: Date? = nil) -> ComposeExisting {
        ComposeExisting(attachment: attachment(uid, taken: taken))
    }

    private func day(_ offset: Double) -> Date {
        Date(timeIntervalSince1970: 1_750_000_000 + offset * 86_400)
    }

    // MARK: - the order of the memo's own pictures

    @Test("the memo's pictures come out in the order they were taken, oldest first")
    func datedPicturesSortAscending() {
        let sorted = ComposeRow.byCaptureInstant([
            existing("a1", taken: day(2)),
            existing("a2", taken: day(0)),
            existing("a3", taken: day(1)),
        ])

        #expect(sorted.map(\.id) == ["a2", "a3", "a1"])
    }

    /// A picture whose file said nothing about when it was taken has no place among the dated
    /// ones: putting it anywhere would be inventing a date for it. So it goes after them, and the
    /// server's order is what decides which of two undated ones comes first.
    @Test("pictures with no capture date follow the dated ones, in the order they arrived in")
    func undatedPicturesKeepTheirOrderAtTheEnd() {
        let sorted = ComposeRow.byCaptureInstant([
            existing("u1"),
            existing("a1", taken: day(1)),
            existing("u2"),
            existing("a2", taken: day(0)),
        ])

        #expect(sorted.map(\.id) == ["a2", "a1", "u1", "u2"])
    }

    /// Two files out of one burst carry the same instant to the second, and `sorted(by:)` is not
    /// a stable sort — without a tie-break the pair could come back either way round and the row
    /// would reshuffle itself between two redraws of the same memo.
    @Test("two pictures taken at the same instant keep the order they arrived in")
    func equalInstantsKeepTheirArrivalOrder() {
        let sorted = ComposeRow.byCaptureInstant([
            existing("b1", taken: day(1)),
            existing("b2", taken: day(1)),
            existing("b3", taken: day(1)),
        ])

        #expect(sorted.map(\.id) == ["b1", "b2", "b3"])
    }

    /// The fence on the case above: the date sort is applied WITHIN the memo's own pictures and
    /// never across the row. A picked file has no capture instant here at all, and one sorted to
    /// the front would put a file that is not on the memo yet ahead of the pictures somebody
    /// opened the sheet to look at.
    @Test("a late picture of the memo's own still comes before anything picked")
    func theSortNeverReachesThePickedHalf() {
        let picked = [ComposeAttachment(label: "one.heic"), ComposeAttachment(label: "two.heic")]

        let items = ComposeRow.items(
            existing: [existing("a1", taken: day(9)), existing("a2", taken: day(0))],
            picked: picked
        )

        #expect(
            items.map(\.id) == [
                "existing-a2", "existing-a1",
                "picked-\(picked[0].id)", "picked-\(picked[1].id)",
            ]
        )
    }

    // MARK: - what the save states about the pictures

    @Test("the memo's own pictures are stated by the uid the memo holds them under")
    func keptPicturesTravelAsTheirUid() {
        let entries = ComposePictureList.entries(items: [
            .existing(existing("a1")), .existing(existing("a2")),
        ])

        #expect(entries == [.kept("a1"), .kept("a2")])
    }

    /// A picked file has no uid until the upload answers, so it travels as its PLACE among the
    /// files the save sends — and those are `ComposeImports.attachments`, which is the row's
    /// picked items that actually have a file. Counting anything else here would name the wrong
    /// upload, and the memo would end up holding the pictures in the wrong order.
    @Test("a picked file is stated by its place among the files the save sends")
    func pickedFilesTravelAsTheirUploadIndex() {
        let media = PickedMedia(
            url: URL(fileURLWithPath: "/dev/null"), filename: "a.jpg", mime: "image/jpeg")
        let ready = ComposeAttachment(media: media, load: .ready, label: "a.jpg")
        let alsoReady = ComposeAttachment(media: media, load: .ready, label: "b.jpg")

        let entries = ComposePictureList.entries(items: [
            .existing(existing("a1")), .picked(ready), .existing(existing("a2")),
            .picked(alsoReady),
        ])

        #expect(entries == [.kept("a1"), .uploading(0), .kept("a2"), .uploading(1)])
    }

    /// The case the cursor exists for: a tile that is still loading or that failed is on the row
    /// but has no file, so it is not in what goes up. Counting it would shift every later picture
    /// one place along and the list would name an upload that was never sent.
    @Test("a tile with no file takes no place in the list and shifts nothing")
    func aTileWithoutAFileIsNotCounted() {
        let media = PickedMedia(
            url: URL(fileURLWithPath: "/dev/null"), filename: "a.jpg", mime: "image/jpeg")
        let loading = ComposeAttachment(label: "still coming")
        let ready = ComposeAttachment(media: media, load: .ready, label: "a.jpg")

        let entries = ComposePictureList.entries(items: [
            .picked(loading), .picked(ready), .existing(existing("a1")),
        ])

        #expect(entries == [.uploading(0), .kept("a1")])
    }

    @Test("a row with nothing in it states an empty list, not nothing at all")
    func anEmptyRowStatesAnEmptyList() {
        #expect(ComposePictureList.entries(items: []) == [])
    }

    // MARK: - what a removal leaves

    @Test("a removed picture is gone from what the row keeps, and the rest stay in order")
    func removalKeepsTheRestInOrder() {
        var removals = ComposeRemovals()
        removals.remove("a2")

        let kept = removals.keeping([existing("a1"), existing("a2"), existing("a3")])

        #expect(kept.map(\.id) == ["a1", "a3"])
    }
}
