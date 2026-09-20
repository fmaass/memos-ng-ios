import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The blurhash was already in every attachment payload and was thrown away. These tests are what
/// says it reaches the screen: one renders a tile whose image has NOT arrived and reads the pixel
/// back, which is the only way to tell a painted placeholder from a grey box.
@MainActor
@Suite("Thumbnails")
struct ThumbnailTests {
    /// `007Da1` carries one component in each direction, so it decodes to exactly one colour —
    /// `#3E7C4F` — in every pixel. That makes the expected pixel a number, not a judgement.
    private static let flatGreenHash = "007Da1"

    @Test("a tile whose image has not arrived is painted with the picture's own colour")
    func stalledLoadingShowsTheDecodedBlurhash() async throws {
        // The decode runs off the main actor now, so it is awaited here exactly as the tile's own
        // `.task` awaits it. What is asserted is unchanged: once the placeholder exists, it is
        // what a tile with no image on it paints.
        #expect(await BlurHashImage.image(for: Self.flatGreenHash) != nil)
        let view = ThumbnailContent(
            attachment: MemoFixture.attachment(blurhash: Self.flatGreenHash),
            phase: .loading,
            image: nil
        )
        let pixel = try #require(
            PixelProbe.centre(of: view, size: CGSize(width: 40, height: 40)),
            "the tile rendered nothing at all"
        )
        #expect(abs(Int(pixel.r) - 0x3E) <= 8, "red was \(pixel.r)")
        #expect(abs(Int(pixel.g) - 0x7C) <= 8, "green was \(pixel.g)")
        #expect(abs(Int(pixel.b) - 0x4F) <= 8, "blue was \(pixel.b)")
    }

    /// The control for the test above: without a hash the same tile paints something else
    /// entirely, so the green in that test came from the decode and not from the tile's own fill.
    @Test("a tile with no blurhash falls back to a plain fill")
    func withoutABlurhashItIsNotGreen() throws {
        let view = ThumbnailContent(
            attachment: MemoFixture.attachment(blurhash: nil),
            phase: .loading,
            image: nil
        )
        let pixel = try #require(PixelProbe.centre(of: view, size: CGSize(width: 40, height: 40)))
        let isTheGreen =
            abs(Int(pixel.r) - 0x3E) <= 8 && abs(Int(pixel.g) - 0x7C) <= 8
            && abs(Int(pixel.b) - 0x4F) <= 8
        #expect(!isTheGreen, "the fallback fill painted the blurhash colour: \(pixel)")
    }

    @Test("a malformed blurhash is a plain fill, not a crash")
    func malformedBlurhashDoesNotCrash() async {
        #expect(await BlurHashImage.image(for: "not-a-blurhash") == nil)
        #expect(await BlurHashImage.image(for: "") == nil)
        #expect(await BlurHashImage.image(for: nil) == nil)
        #expect(await BlurHashImage.image(for: String(repeating: "L", count: 8_000_000)) == nil)
        #expect(await BlurHashImage.image(for: Self.flatGreenHash) != nil)
    }

    @Test("a decoded blurhash is derived once and reused")
    func decodesAreCached() async throws {
        let first = try #require(await BlurHashImage.uiImage(for: Self.flatGreenHash))
        let second = try #require(await BlurHashImage.uiImage(for: Self.flatGreenHash))
        #expect(first === second)
    }

    /// The synchronous path a view body takes. Nothing is cached until the off-main decode has
    /// finished, and everything is afterwards — which is what keeps a tile scrolled back into
    /// view from flashing its plain fill again.
    @Test("a hash is answered synchronously only after it has been decoded")
    func theCacheIsTheSynchronousPath() async {
        // Its own hash, so no other test in this suite can have warmed it first.
        let hash = "001{~h"
        #expect(BlurHashImage.cached(for: hash) == nil)
        #expect(await BlurHashImage.image(for: hash) != nil)
        #expect(BlurHashImage.cached(for: hash) != nil)
        #expect(BlurHashImage.cached(for: nil) == nil)
    }

}

/// The state a tile is in, three ways.
///
/// The first real post from the phone came back a card of "!" marks. Nothing was broken: the memo
/// existed, the uploads were linked, and the server had simply not derived their tiers yet — so the
/// tile asked for a picture that was not there, the fetch came back empty, and every one of those
/// photos wore the glyph that means "this file is ruined". The projection here is what separates
/// waiting from failed, and these are the assertions that keep them separate.
@MainActor
@Suite("Waiting, ready, failed")
struct AttachmentWaitingTests {
    private static let flatGreenHash = "007Da1"

    private func attachment(_ status: AttachmentStatus, blurhash: String? = flatGreenHash)
        -> MemoAttachment
    {
        MemoAttachment(
            uid: "a1",
            mime: "image/jpeg",
            status: status,
            blurhash: blurhash,
            width: 1000,
            height: 1000,
            thumbnailURL: URL(string: "https://memos.example.invalid/thumb")
        )
    }

    private func whitish(_ view: some View) -> Int? {
        guard let pixels = PixelGrid.of(view, size: CGSize(width: 40, height: 40)) else {
            return nil
        }
        return pixels.flatMap { $0 }.filter { $0.r > 200 && $0.g > 200 && $0.b > 200 }.count
    }

    /// A case per status, and the three answers are genuinely three.
    @Test("every status the server can send projects to one of exactly three treatments")
    func readinessCoversEveryStatus() {
        #expect(attachment(.ready).readiness == .ready)
        #expect(attachment(.pending).readiness == .waiting)
        #expect(attachment(.processing).readiness == .waiting)
        #expect(attachment(.uploading).readiness == .waiting)
        #expect(attachment(.failed).readiness == .failed)

        let all: Set<AttachmentReadiness> = [.ready, .waiting, .failed]
        #expect(all.count == 3, "two of the three treatments are the same treatment")
    }

    /// The projection, per input category rather than per happy path. The load state of a WAITING
    /// attachment is deliberately irrelevant: its derived-tier URL is already in the payload and a
    /// fetch for it 404s, which is exactly how the failure glyph got there in the first place.
    @Test("only an attachment the server failed on is drawn as a failure")
    func phaseIsThreeWay() {
        typealias Tile = AttachmentThumbnail
        // Waiting: no glyph, whatever the fetch did.
        #expect(
            Tile.phase(readiness: .waiting, hasImage: false, hasURL: true, loadFailed: false)
                == .waiting
        )
        #expect(
            Tile.phase(readiness: .waiting, hasImage: false, hasURL: true, loadFailed: true)
                == .waiting,
            "a 404 on a tier the server has not made yet was drawn as a broken file"
        )
        #expect(
            Tile.phase(readiness: .waiting, hasImage: false, hasURL: false, loadFailed: false)
                == .waiting
        )
        // A picture that arrived anyway is shown rather than covered up.
        #expect(
            Tile.phase(readiness: .waiting, hasImage: true, hasURL: true, loadFailed: false)
                == .loaded
        )
        // Failed: the glyph, whatever else is true.
        #expect(
            Tile.phase(readiness: .failed, hasImage: false, hasURL: true, loadFailed: false)
                == .failed
        )
        #expect(
            Tile.phase(readiness: .failed, hasImage: true, hasURL: true, loadFailed: false)
                == .failed
        )
        // Ready: unchanged from before — the tiers are supposed to exist, so a fetch that comes
        // back with nothing IS a failure of this one.
        #expect(
            Tile.phase(readiness: .ready, hasImage: true, hasURL: true, loadFailed: false)
                == .loaded
        )
        #expect(
            Tile.phase(readiness: .ready, hasImage: false, hasURL: true, loadFailed: false)
                == .loading
        )
        #expect(
            Tile.phase(readiness: .ready, hasImage: false, hasURL: true, loadFailed: true)
                == .failed
        )
        #expect(
            Tile.phase(readiness: .ready, hasImage: false, hasURL: false, loadFailed: false)
                == .failed
        )
    }

    /// What a person actually sees, counted in pixels: the warning triangle is on the failed tile
    /// and on no other. A projection that said the right word while the view drew the same glyph
    /// anyway would pass every test above.
    @Test("the failure glyph is drawn for a failed attachment and for nothing else")
    func onlyTheFailedTileWearsTheGlyph() async throws {
        _ = await BlurHashImage.image(for: Self.flatGreenHash)
        let failed = try #require(
            whitish(ThumbnailContent(attachment: attachment(.failed), phase: .failed, image: nil))
        )
        let waiting = try #require(
            whitish(ThumbnailContent(attachment: attachment(.pending), phase: .waiting, image: nil))
        )
        let loading = try #require(
            whitish(ThumbnailContent(attachment: attachment(.ready), phase: .loading, image: nil))
        )
        // The control: the glyph really is visible in pixels, so the zeroes below mean something.
        #expect(failed > 10, "the failure glyph did not render at all (\(failed) pixels)")
        #expect(waiting == 0, "a waiting tile is wearing the failure glyph")
        #expect(loading == 0)
    }

    /// The waiting treatment sits OVER the picture's own colours rather than replacing them with a
    /// grey box — the blurhash is what says which photo is on its way.
    ///
    /// The veil is asserted on ITSELF, over a known colour, rather than by telling a hosted tile
    /// that Reduce Motion is on: `\.accessibilityReduceMotion` is a read-only environment value,
    /// so a test cannot set it, and the travelling form sits off the tile's edge at rest.
    @Test("a waiting tile is the blurhash with a veil over it, not a grey box")
    func waitingKeepsTheBlurhash() async throws {
        _ = await BlurHashImage.image(for: Self.flatGreenHash)
        let waiting = try #require(
            PixelProbe.centre(
                of: ThumbnailContent(
                    attachment: attachment(.pending), phase: .waiting, image: nil
                ),
                size: CGSize(width: 40, height: 40)
            )
        )
        // Still the picture's colour: green is what dominates, as it does underneath.
        #expect(
            waiting.g > waiting.r && waiting.g > waiting.b,
            "the waiting tile is not the blurhash any more: \(waiting)"
        )

        // And the veil really does lighten what it is over — so a waiting tile cannot be mistaken
        // for one that is simply sitting there.
        let base = Color(red: 0x3E / 255.0, green: 0x7C / 255.0, blue: 0x4F / 255.0)
        let size = CGSize(width: 40, height: 40)
        let bare = try #require(PixelProbe.centre(of: Rectangle().fill(base), size: size))
        let veiled = try #require(
            PixelProbe.centre(
                of: Rectangle().fill(base).overlay { WaitingVeil(motion: .still) },
                size: size
            )
        )
        #expect(
            veiled.r > bare.r && veiled.g > bare.g && veiled.b > bare.b,
            "the veil did not lighten the tile at all: \(bare) -> \(veiled)"
        )
    }

    /// Reduce Motion is a request for NO movement, not for gentler movement.
    @Test("Reduce Motion makes the waiting treatment stand still")
    func reduceMotionIsStill() {
        #expect(WaitingTreatment.motion(reduceMotion: true) == .still)
        #expect(WaitingTreatment.motion(reduceMotion: false) == .shimmer)
        #expect(WaitingTreatment.Motion.still != WaitingTreatment.Motion.shimmer)
    }

    /// Whatever it draws, a veil may never change the size of the tile it is a veil over.
    @Test("neither treatment resizes the tile")
    func theVeilNeverResizes() {
        for motion in [WaitingTreatment.Motion.still, .shimmer] {
            let size = LayoutProbe.size(WaitingVeil(motion: motion), width: 120, height: 80)
            #expect(abs(size.width - 120) < 0.5 && abs(size.height - 80) < 0.5, "\(size)")
        }
        let tile = LayoutProbe.size(
            ThumbnailContent(attachment: attachment(.pending), phase: .waiting, image: nil),
            width: 120,
            height: 80
        )
        #expect(abs(tile.width - 120) < 0.5 && abs(tile.height - 80) < 0.5, "\(tile)")
    }

    /// A video whose poster has not been derived yet has nothing to play, so it does not offer to.
    @Test("a waiting video shows no play button")
    func waitingVideoDoesNotOfferToPlay() async throws {
        _ = await BlurHashImage.image(for: Self.flatGreenHash)
        let video = MemoAttachment(
            uid: "v1",
            mime: "video/quicktime",
            status: .pending,
            blurhash: Self.flatGreenHash,
            width: 1000,
            height: 1000
        )
        let waiting = try #require(
            whitish(ThumbnailContent(attachment: video, phase: .waiting, image: nil))
        )
        // The control: the same video, ready, DOES draw the play glyph in white.
        var ready = video
        ready.status = .ready
        let offered = try #require(
            whitish(ThumbnailContent(attachment: ready, phase: .loading, image: nil))
        )
        #expect(offered > 10, "the play glyph did not render at all (\(offered) pixels)")
        #expect(waiting == 0, "a video with no poster yet offered to play")
    }
}

/// What a view knows about its own picture, and the one rule that decides whether it is worth
/// asking for again.
///
/// Driven as a value rather than through a hosted view and a network, because the cases that
/// matter are the REFUSALS — a signal that arrives while a fetch is out, a signal for a view
/// already showing its picture — and a rendered tile is at its worst at showing what did not
/// happen.
@MainActor
@Suite("Asking for a picture again")
struct PictureLoadTests {
    private static let key = MediaImageKey(uid: "owed", tier: "thumb")
    private static let other = MediaImageKey(uid: "owed-other", tier: "thumb")

    /// One whole load, exactly as a view runs it: claimed before anything is awaited, settled with
    /// the serial it claimed, released however it left.
    private func load(
        _ answer: MediaImageAnswer,
        for key: MediaImageKey,
        into load: inout PictureLoad
    ) {
        let serial = load.claim()
        load.settle(answer, for: key, serial: serial)
        load.release(serial)
    }

    /// The tile's projection of the state below, so these cases are about the glyph a person sees
    /// and not only about a field.
    private func tilePhase(_ load: PictureLoad, for key: MediaImageKey) -> ThumbnailPhase {
        AttachmentThumbnail.phase(
            readiness: .ready,
            hasImage: load.captured?.key == key,
            hasURL: true,
            loadFailed: load.failedKey == key
        )
    }

    /// The whole of the first complaint: only an ANSWER may fail a picture.
    @Test("a fetch nobody answered leaves the tile loading; a refused one fails it")
    func onlyAnAnswerFailsAPicture() {
        var abandoned = PictureLoad()
        load(.interrupted, for: Self.key, into: &abandoned)
        #expect(abandoned.failedKey == nil, "a cancelled fetch was painted as a broken file")
        #expect(tilePhase(abandoned, for: Self.key) == .loading)

        // The control: the same transition for an answer that came back with no picture in it
        // does fail the tile, so the line above is about the difference and not about the state
        // machine refusing to fail anything at all.
        var refused = PictureLoad()
        load(.unavailable, for: Self.key, into: &refused)
        #expect(refused.failedKey == Self.key)
        #expect(tilePhase(refused, for: Self.key) == .failed)

        // And a picture clears the failure of the key it is for, and of no other.
        var recovered = refused
        load(.picture(UIImage()), for: Self.other, into: &recovered)
        #expect(recovered.failedKey == Self.key, "another picture's arrival cleared this failure")
        load(.picture(UIImage()), for: Self.key, into: &recovered)
        #expect(recovered.failedKey == nil)
        #expect(tilePhase(recovered, for: Self.key) == .loaded)
    }

    /// The rule itself, per input category rather than per happy path.
    @Test("only a view showing nothing with nothing out is asked again")
    func theRuleRefusesEveryOtherView() {
        var owed = PictureLoad()
        load(.unavailable, for: Self.key, into: &owed)
        #expect(owed.isOwedAPicture(showing: false))
        let askedForTheFailed = owed.askAgain(showing: false)
        #expect(askedForTheFailed, "a failed tile was left holding its failure")
        #expect(owed.attempt == 1, "the attempt is what the load hangs off, and it did not move")

        var showing = PictureLoad()
        load(.picture(UIImage()), for: Self.key, into: &showing)
        #expect(!showing.isOwedAPicture(showing: true))
        let askedForTheShown = showing.askAgain(showing: true)
        #expect(!askedForTheShown, "a picture in hand was fetched again")
        #expect(showing.attempt == 0)

        var fetching = PictureLoad()
        _ = fetching.claim()
        #expect(!fetching.isOwedAPicture(showing: false))
        let askedWhileFetching = fetching.askAgain(showing: false)
        #expect(!askedWhileFetching, "the fetch already out IS the attempt")
        #expect(fetching.attempt == 0)
    }

    /// Two signals inside the gap between the attempt being decided and the replacement load
    /// starting. The claim is taken where the DECISION is, so the second one has something to be
    /// refused by — without it both would raise an attempt and two fetches would go out for one
    /// picture.
    @Test("a second signal before the load has started is refused")
    func aSecondSignalInTheGapIsRefused() {
        var failed = PictureLoad()
        load(.unavailable, for: Self.key, into: &failed)
        let first = failed.askAgain(showing: false)
        #expect(first)
        let raised = failed.attempt

        let second = failed.askAgain(showing: false)
        #expect(!second, "the gap before the load starts was unfenced")
        #expect(failed.attempt == raised, "two signals became two loads for one picture")
    }

    /// The other half of the same overlap. A changed link starts a load while the one it replaced
    /// can still be on the wire — that is accepted, and the request out on the old link is the one
    /// whose answer is about a question this view has stopped asking. Its refusal must not become
    /// a warning triangle over a load that is still out.
    @Test("an answer to a load that was superseded settles nothing")
    func aSupersededAnswerSettlesNothing() {
        var replaced = PictureLoad()
        let superseded = replaced.claim()
        let live = replaced.claim()

        let refusalApplied = replaced.settle(.unavailable, for: Self.key, serial: superseded)
        #expect(!refusalApplied)
        #expect(
            replaced.failedKey == nil,
            "a link this view had stopped asking about failed the picture it is still loading"
        )
        let pictureApplied = replaced.settle(.picture(UIImage()), for: Self.key, serial: superseded)
        #expect(!pictureApplied)
        #expect(replaced.captured == nil)

        // The control: the load that still holds the claim settles.
        let liveApplied = replaced.settle(.unavailable, for: Self.key, serial: live)
        #expect(liveApplied)
        #expect(replaced.failedKey == Self.key)
    }

    /// A changed link is not a retry: it cancels this load and starts another, and the cancelled
    /// request may still be on the wire when the new one goes. The one that ends LAST must not
    /// clear a claim it no longer holds, or the next signal sees a view owed a picture and asks
    /// for one already coming.
    @Test("a claim is released only by the fetch that still holds it")
    func aClaimIsReleasedBySerial() {
        var replaced = PictureLoad()
        let cancelled = replaced.claim()
        let live = replaced.claim()
        #expect(cancelled != live)

        replaced.release(cancelled)
        #expect(
            !replaced.isOwedAPicture(showing: false),
            "the view forgot the request it still has out"
        )

        replaced.release(live)
        #expect(replaced.isOwedAPicture(showing: false))
    }
}

@MainActor
@Suite("Picked media thumbnails")
struct PickedThumbnailSourceTests {
    @Test("a video is recognised from its mime type, whatever the container")
    func videoDetection() {
        #expect(PickedThumbnailSource.isVideo(mime: "video/quicktime"))
        #expect(PickedThumbnailSource.isVideo(mime: "video/mp4"))
        #expect(!PickedThumbnailSource.isVideo(mime: "image/heic"))
        #expect(!PickedThumbnailSource.isVideo(mime: "application/octet-stream"))
    }

    /// ImageIO reads a maximum pixel size of 0 as "no limit" and decodes the full image, so the
    /// budget is never allowed to round down to nothing.
    @Test("the decode budget is whole pixels and never zero")
    func pixelBudget() {
        #expect(PickedThumbnailSource.maxPixelSize(forPointSize: 72, scale: 3) == 216)
        #expect(PickedThumbnailSource.maxPixelSize(forPointSize: 72, scale: 2) == 144)
        #expect(PickedThumbnailSource.maxPixelSize(forPointSize: 0.2, scale: 1) == 1)
        #expect(PickedThumbnailSource.maxPixelSize(forPointSize: 72, scale: 0) == 72)
        #expect(PickedThumbnailSource.maxPixelSize(forPointSize: 0, scale: 3) == 1)
    }

    @Test("a file that is not an image yields no thumbnail rather than a broken one")
    func unreadableFile() throws {
        let url = URL.temporaryDirectory.appending(path: "not-an-image-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PickedThumbnailSource.thumbnail(at: url, maxPixelSize: 64) == nil)
    }
}
