import Foundation
import MemosCore
import MemosOutbox
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The pictures a memo already has, on the screen that edits it.
///
/// The row shows what the memo holds at the moment the sheet opens, ahead of anything picked in
/// the sheet itself: the picture somebody is about to describe or correct is the thing that has
/// to be in front of them while they do it. What the sheet may not do is ACT on that list —
/// nothing here removes a picture and a save names none of them — so these cases hold both
/// halves: that the row shows the memo's own pictures, and that it offers nothing that would
/// change them.
@MainActor
@Suite("The compose row on an edit")
struct ComposeExistingPicturesTests {
    private let created = Date(timeIntervalSince1970: 1_750_000_000)

    private func attachment(_ uid: String) -> MemoAttachment {
        MemoAttachment(uid: uid, mime: "image/jpeg", status: .ready)
    }

    private func mode(_ attachments: [MemoAttachment]) -> ComposeView.Mode {
        .edit(uid: "m1", content: "the boiler man", createdAt: created, attachments: attachments)
    }

    @Test("an edit sheet shows the pictures the memo already has")
    func theEditSheetShowsTheMemosPictures() {
        let labels = ScreenProbe.labels(
            of: ComposeView(mode: mode([attachment("a1"), attachment("a2")])) { _ in .saved }
        )

        // The positive control: without it, a missing row below would only prove the probe saw
        // nothing whatsoever.
        #expect(
            labels.contains { $0.contains("Save") },
            "the probe found nothing of the sheet at all: \(labels)"
        )
        #expect(
            labels.contains("2 files attached"),
            "the memo's own pictures are not in the row: \(labels)"
        )
    }

    @Test("a picture the memo already has offers no way to remove it")
    func anExistingTileOffersNoRemoveControl() {
        let existing = ComposeExisting(attachment: attachment("a1"))
        let labels = ScreenProbe.labels(of: PickedThumbnailRow(items: [.existing(existing)]))

        // The control: the probe can see the row itself, so the absence below is the tile's and
        // not the probe's.
        #expect(labels.contains("1 file attached"), "the probe saw nothing of the row: \(labels)")
        // Removal is a change to what the memo holds, which is a request this release does not
        // send at all. An affordance that did nothing would be a lie on the screen.
        #expect(
            !labels.contains {
                $0.localizedCaseInsensitiveContains("remove")
                    || $0.localizedCaseInsensitiveContains("delete")
            },
            "an existing picture offered to be got rid of: \(labels)"
        )
    }

    // MARK: - what each entry to the sheet carries

    @Test("the timeline's Edit opens on the memo's pictures")
    func theTimelineCarriesTheMemosPictures() {
        let memo = MemoFixture.memo(uid: "m2", attachments: [attachment("a1"), attachment("a2")])

        #expect(uids(of: TimelineView.editMode(for: memo)) == ["a1", "a2"])
    }

    @Test("the memo's own screen opens its Edit on the same pictures")
    func theDetailCarriesTheMemosPictures() throws {
        let memo = MemoFixture.memo(uid: "m3", attachments: [attachment("a1"), attachment("a2")])

        let mode = try #require(MemoDetailPresentation.editMode(for: memo))
        #expect(uids(of: mode) == ["a1", "a2"])
    }

    // MARK: - the order

    @Test("the memo's own pictures come first, then what was picked")
    func existingPicturesComeFirst() {
        let picked = [ComposeAttachment(label: "one.heic"), ComposeAttachment(label: "two.heic")]

        let items = ComposeRow.items(
            existing: [
                ComposeExisting(attachment: attachment("a1")),
                ComposeExisting(attachment: attachment("a2")),
            ],
            picked: picked
        )

        #expect(
            items.map(\.id) == [
                "existing-a1", "existing-a2",
                "picked-\(picked[0].id)", "picked-\(picked[1].id)",
            ]
        )
    }

    /// The control for the case above: with nothing of the memo's own in it, the row is exactly
    /// the order the imports are in — which is capture order, not pick order. Without this, an
    /// ordering that quietly sorted or reversed the picked half would satisfy the assertion above.
    @Test("with nothing but picked files the row is the import order, untouched")
    func pickedOnlyKeepsTheImportOrder() async {
        let imports = ComposeImports(
            zone: TimeZone(identifier: "Europe/Berlin")!,
            readCapture: { media in
                CaptureReading(
                    instant: media.filename == "first.heic"
                        ? Date(timeIntervalSince1970: 1_600_000_000)
                        : Date(timeIntervalSince1970: 1_700_000_000),
                    civil: nil,
                    source: .exif
                )
            })
        await imports.load(["second", "first"], stamp: imports.selected()) { name in
            .file(
                PickedMedia(
                    url: URL(filePath: "/tmp/\(name).heic"),
                    filename: "\(name).heic",
                    mime: "image/heic"
                )
            )
        }
        await settleTasks()

        // Picked second, taken first: the row must hand on what the imports say, not what the
        // picker happened to answer first.
        #expect(imports.ordered.map(\.label) == ["first.heic", "second.heic"])
        #expect(
            ComposeRow.items(existing: [], picked: imports.ordered).map(\.id)
                == imports.ordered.map { "picked-\($0.id)" }
        )
    }

    private func uids(of mode: ComposeView.Mode) -> [String] {
        guard case .edit(_, _, _, let attachments) = mode else { return [] }
        return attachments.map(\.uid)
    }
}

/// `007Da1` carries one component in each direction, so it decodes to exactly one colour —
/// `#3E7C4F`, a DARK green — in every pixel. The vector `ThumbnailTests` uses, for the same
/// reason: it makes the expected pixel a number rather than a judgement.
private let flatGreenHash = "007Da1"

/// The rendering witness, and why it is declared in the loader's suite rather than beside the
/// tests above: `MediaImageLoader.store` and `.transport` are process-wide, so seeding a decoded
/// photograph is only exact inside the `.serialized` suite that owns them and installs its own
/// store. A test in an extension is a test of that suite.
extension MediaImageLoaderTests {
    /// The summary label counts the row's items and says nothing about what was drawn, and a
    /// colour check that accepted the blurhash would pass for a row that never fetched the
    /// photograph at all. So: a flat GREEN blurhash, a flat RED photograph already decoded, and
    /// the assertion is that the red one is what the row paints.
    @Test("an existing picture in the compose row paints the photograph itself")
    func theComposeRowPaintsAnExistingPicture() async throws {
        let attachment = MediaFixture.attachment(uid: "compose-row", blurhash: flatGreenHash)
        // Both layers are warmed before anything is drawn, so the pixel below can only be saying
        // which of them the row chose — not which of them happened to arrive first. The
        // photograph is seeded through the loader itself, so the tile finds it in the cache and
        // no network is touched.
        #expect(await BlurHashImage.image(for: flatGreenHash) != nil)
        let key = MediaImageLoader.key(for: attachment, tier: .thumb)
        let url = try #require(MemoPresentation.url(for: attachment, tier: .thumb))
        await withTransport(ScriptedTransport(payload: MediaFixture.png(.red))) {
            #expect(await MediaImageLoader.uiImage(for: key, url: url) != nil)
        }

        let tile = DesignTokens.Metric.pickedThumbnail
        let pixel = try #require(
            PixelProbe.centreOnScreen(
                of: PickedThumbnailRow(
                    items: [.existing(ComposeExisting(attachment: attachment))]
                ),
                size: CGSize(width: tile, height: tile)
            ),
            "the row rendered nothing at all"
        )
        // The backdrop would read about 62/124/79, an empty slot something else again.
        #expect(pixel.r > 200, "red was \(pixel.r) — the photograph did not paint")
        #expect(pixel.g < 80, "green was \(pixel.g) — the blurhash is all the row drew")
    }
}
