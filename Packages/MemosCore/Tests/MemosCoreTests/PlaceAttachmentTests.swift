import Foundation
import MemosCore
import Testing

/// What a pin becomes when the viewer opens on it.
///
/// The viewer takes attachments, not markers, so this one conversion decides what every photo
/// opened from the map can do afterwards — which memo "Show in memo" asks for, and whether Share
/// and Save appear at all.
@Suite("A marker as the viewer sees it")
struct PlaceAttachmentTests {
    private func marker() -> PlaceMarker {
        PlaceMarker(
            uid: "att-7",
            memoUID: "memo-3",
            mime: "image/jpeg",
            mine: true,
            width: 4000,
            height: 3000,
            latitude: 47.2,
            longitude: 8.4,
            takenAt: placeDate("2026-01-01T00:00:00Z"),
            thumbnailURL: URL(string: "https://example.invalid/assets/att-7/thumb"),
            previewURL: URL(string: "https://example.invalid/assets/att-7/preview"),
            webURL: URL(string: "https://example.invalid/assets/att-7/web"),
            posterURL: URL(string: "https://example.invalid/assets/att-7/poster"),
            downloadURL: URL(string: "https://example.invalid/assets/att-7/download"),
            blurhash: "LEHV6n"
        )
    }

    @Test("carries the original through, so Share and Save survive the trip from the map")
    func carriesTheOriginal() {
        let attachment = MemoAttachment(marker())
        let assets = "https://example.invalid/assets/att-7"

        #expect(attachment.downloadURL?.absoluteString == "\(assets)/download")
        // A control on the four signed tiers: an adapter that dropped every URL would still be
        // reported as carrying the original if the line above were the only one asked.
        #expect(attachment.previewURL?.absoluteString == "\(assets)/preview")
    }

    @Test("is ready, because the markers query answers with nothing else")
    func isReady() {
        #expect(MemoAttachment(marker()).status == .ready)
    }

    @Test("names the memo the marker hangs on, not the file itself")
    func namesTheMemo() {
        let attachment = MemoAttachment(marker())

        #expect(attachment.memoUID == "memo-3")
        #expect(attachment.uid == "att-7", "control: the file's own uid is still the file's")
    }
}
