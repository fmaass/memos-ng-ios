import Foundation
import MemosCore
import MemosFeatures
import Testing

@Suite("MemoPresentation")
struct MemoPresentationTests {
    private func attachment() -> MemoAttachment {
        MemoAttachment(
            uid: "a1",
            mime: "image/jpeg",
            status: .ready,
            blurhash: nil,
            width: 4000,
            height: 3000,
            duration: nil,
            thumbnailURL: URL(string: "https://memos.example.invalid/api/attachments/a1/thumb"),
            previewURL: URL(string: "https://memos.example.invalid/api/attachments/a1/mobile"),
            webURL: nil,
            posterURL: nil
        )
    }

    @Test("a grid slot asks for the thumb tier, a full-width slot for mobile")
    func tierSelection() {
        #expect(MemoPresentation.tier(forPointWidth: 120, scale: 2) == .thumb)
        #expect(MemoPresentation.tier(forPointWidth: 160, scale: 2) == .thumb)
        #expect(MemoPresentation.tier(forPointWidth: 161, scale: 2) == .mobile)
        #expect(MemoPresentation.tier(forPointWidth: 390, scale: 3) == .mobile)
    }

    @Test("each tier resolves to its own rendition URL")
    func urlSelection() {
        let attachment = attachment()
        #expect(MemoPresentation.url(for: attachment, tier: .thumb) == attachment.thumbnailURL)
        #expect(MemoPresentation.url(for: attachment, tier: .mobile) == attachment.previewURL)
    }

    @Test("aspect ratio falls back to a square rather than dividing by zero")
    func aspectRatio() {
        #expect(abs(attachment().aspectRatio - 4.0 / 3.0) < 0.0001)
        var missing = attachment()
        missing.width = nil
        #expect(missing.aspectRatio == 1)
    }

    @Test("a memo whose whole body is tags renders no body")
    func renderableBody() {
        #expect(!MemoPresentation.hasRenderableBody("#curated #trip"))
        #expect(!MemoPresentation.hasRenderableBody("   "))
        #expect(MemoPresentation.hasRenderableBody("#curated\nreal content"))
    }

    @Test("the task rows are the rendered ones, in rendered order")
    func taskRows() {
        let content = "```\n- [ ] fenced\n```\n- [x] done\n- [ ] todo\n- plain"
        let tasks = MemoPresentation.tasks(in: content)
        #expect(tasks.map(\.text) == ["done", "todo"])
        #expect(tasks.map(\.checked) == [true, false])
    }
}

@Suite("DebugCredentials")
struct DebugCredentialsTests {
    @Test("both variables together are a credential")
    func bothPresent() {
        let credentials = DebugCredentials.fromEnvironment([
            "MEMOS_SERVER": "https://memos.example.invalid",
            "MEMOS_PAT": "memos_pat_x",
        ])
        #expect(credentials?.serverAddress == "https://memos.example.invalid")
        #expect(credentials?.token == "memos_pat_x")
    }

    @Test("one without the other is nothing")
    func partial() {
        #expect(DebugCredentials.fromEnvironment(["MEMOS_SERVER": "https://x.invalid"]) == nil)
        #expect(DebugCredentials.fromEnvironment(["MEMOS_PAT": "memos_pat_x"]) == nil)
        #expect(DebugCredentials.fromEnvironment([:]) == nil)
    }

    @Test("blank values are not a credential")
    func blank() {
        #expect(
            DebugCredentials.fromEnvironment(["MEMOS_SERVER": "  ", "MEMOS_PAT": "memos_pat_x"])
                == nil
        )
        #expect(
            DebugCredentials.fromEnvironment(["MEMOS_SERVER": "https://x.invalid", "MEMOS_PAT": ""])
                == nil
        )
    }
}

extension MemoPresentationTests {
    private static func video(_ overrides: (inout MemoAttachment) -> Void = { _ in })
        -> MemoAttachment
    {
        var attachment = MemoAttachment(
            uid: "v1",
            mime: "video/mp4",
            status: .ready,
            thumbnailURL: URL(string: "https://example.invalid/thumb"),
            previewURL: URL(string: "https://example.invalid/mobile"),
            webURL: URL(string: "https://example.invalid/web.mp4"),
            posterURL: URL(string: "https://example.invalid/poster")
        )
        overrides(&attachment)
        return attachment
    }

    @Test("a video's still is its poster, whatever tier a slot asked for")
    func videoTilesUseThePoster() {
        let video = Self.video()
        #expect(MemoPresentation.url(for: video, tier: .thumb)?.lastPathComponent == "poster")
        #expect(MemoPresentation.url(for: video, tier: .mobile)?.lastPathComponent == "poster")
    }

    @Test("a video without a poster falls back rather than showing a warning triangle")
    func videoWithoutPosterFallsBack() {
        let video = Self.video { $0.posterURL = nil }
        #expect(MemoPresentation.url(for: video, tier: .thumb)?.lastPathComponent == "thumb")
    }

    @Test("playback streams the derived rendition and only exists for videos")
    func playbackIsTheDerivedRendition() {
        #expect(
            MemoPresentation.playbackURL(for: Self.video())?.lastPathComponent == "web.mp4"
        )
        let image = Self.video { $0.mime = "image/jpeg" }
        #expect(MemoPresentation.playbackURL(for: image) == nil)
    }
}

/// The detail view shows the picture; the timeline shows a tile of it. Which is which is a
/// decision, so it is a value a test can read rather than a modifier buried in a view body.
@Suite("Attachment slots")
struct AttachmentSlotTests {
    private func attachment(width: Int?, height: Int?) -> MemoAttachment {
        MemoAttachment(
            uid: "a1",
            mime: "image/jpeg",
            status: .ready,
            width: width,
            height: height,
            thumbnailURL: URL(string: "https://memos.example.invalid/thumb"),
            previewURL: URL(string: "https://memos.example.invalid/mobile")
        )
    }

    @Test("the detail view shows the whole picture, at the proportions the server measured")
    func detailFitsTheMeasuredShape() {
        let portrait = MemoPresentation.detailSlot(for: attachment(width: 3000, height: 4000))
        #expect(portrait.contentMode == .fit)
        #expect(abs(portrait.aspectRatio - 0.75) < 0.0001)

        let landscape = MemoPresentation.detailSlot(for: attachment(width: 4032, height: 3024))
        #expect(landscape.contentMode == .fit)
        #expect(abs(landscape.aspectRatio - 4.0 / 3.0) < 0.0001)

        let panorama = MemoPresentation.detailSlot(for: attachment(width: 8000, height: 2000))
        #expect(abs(panorama.aspectRatio - 4.0) < 0.0001)
    }

    /// Without measurements there is nothing to derive, and a ratio of zero is a container with
    /// no height that renders as nothing at all. 4:3 is wrong in the direction that letterboxes.
    @Test("an unmeasured attachment falls back to a shape rather than to nothing")
    func detailFallsBackToFourThirds() {
        for missing in [(nil, 400), (300, nil), (nil, nil), (0, 400), (300, 0)] {
            let slot = MemoPresentation.detailSlot(
                for: attachment(width: missing.0, height: missing.1)
            )
            #expect(slot.contentMode == .fit)
            #expect(abs(slot.aspectRatio - 4.0 / 3.0) < 0.0001, "got \(slot.aspectRatio)")
            #expect(slot.aspectRatio > 0)
        }
    }

    /// A video is a picture on this screen too — its poster gets the same whole-frame treatment,
    /// which is what keeps the play button in the middle of the image rather than of a crop.
    ///
    /// The cases are deliberately in DIFFERENT DIRECTIONS from the 4:3 fallback: portrait is
    /// below it, landscape above it. A regression that forced every video to 4:3 would have to
    /// fail both, and could not be hidden by a fixture that happens to sit near the fallback.
    /// The real library is exactly these two shapes — 1080x1920 and 1920x1080 from an iPhone.
    @Test("a video's poster is fitted at the shape it was shot in")
    func videosAreFittedToo() {
        var portrait = attachment(width: 1080, height: 1920)
        portrait.mime = "video/quicktime"
        portrait.posterURL = URL(string: "https://memos.example.invalid/poster")
        let tall = MemoPresentation.detailSlot(for: portrait)
        #expect(tall.contentMode == .fit)
        #expect(abs(tall.aspectRatio - 0.5625) < 0.0001, "portrait video got \(tall.aspectRatio)")
        #expect(tall.aspectRatio < 1, "a portrait video must not be laid out wider than tall")

        var landscape = attachment(width: 1920, height: 1080)
        landscape.mime = "video/quicktime"
        landscape.posterURL = URL(string: "https://memos.example.invalid/poster")
        let wide = MemoPresentation.detailSlot(for: landscape)
        #expect(wide.contentMode == .fit)
        #expect(
            abs(wide.aspectRatio - 16.0 / 9.0) < 0.0001,
            "landscape video got \(wide.aspectRatio)"
        )

        // Neither is the fallback, and they bracket it — so nothing can pass all three by
        // accidentally returning one number.
        #expect(tall.aspectRatio < 4.0 / 3.0)
        #expect(wide.aspectRatio > 4.0 / 3.0)
    }

    /// The fallback is for an attachment nobody measured, and for nothing else. A video WITH
    /// measurements must never reach it — that is the whole of this defect class.
    @Test("a video falls back to 4:3 only when its metadata is genuinely absent")
    func videosFallBackOnlyWhenUnmeasured() {
        var unmeasured = attachment(width: nil, height: nil)
        unmeasured.mime = "video/quicktime"
        unmeasured.posterURL = URL(string: "https://memos.example.invalid/poster")
        let slot = MemoPresentation.detailSlot(for: unmeasured)
        #expect(abs(slot.aspectRatio - 4.0 / 3.0) < 0.0001)

        // A measured video of the SAME shape as the fallback is still measured, not fallen back:
        // 4:3 here is a fact about the video rather than a shrug.
        var fourThree = attachment(width: 1440, height: 1080)
        fourThree.mime = "video/quicktime"
        #expect(fourThree.measuredAspectRatio != nil)
        #expect(unmeasured.measuredAspectRatio == nil)
    }

    /// The browse surface is deliberately the other way round: tiles crop so a row lines up.
    @Test("the timeline still crops, because a row that does not line up is not a row")
    func timelineTilesStillFill() {
        #expect(MemoPresentation.gridSlot.contentMode == .fill)
        #expect(MemoPresentation.gridSlot.aspectRatio == 1)
        let solo = MemoPresentation.timelineSlot(for: attachment(width: 3000, height: 4000))
        #expect(solo.contentMode == .fill)
        #expect(abs(solo.aspectRatio - 0.75) < 0.0001)
        // An unmeasured tile is square there, which is what a grid wants — not 4:3.
        #expect(
            MemoPresentation.timelineSlot(for: attachment(width: nil, height: nil))
                .aspectRatio == 1)
    }

    @Test("a measurement the server did not make is reported as missing, not as a square")
    func measuredRatioIsHonest() {
        #expect(attachment(width: nil, height: nil).measuredAspectRatio == nil)
        #expect(attachment(width: 0, height: 400).measuredAspectRatio == nil)
        #expect(attachment(width: 4000, height: 3000).measuredAspectRatio != nil)
        // The old accessor keeps its square fallback for the callers that want one.
        #expect(attachment(width: nil, height: nil).aspectRatio == 1)
    }

    // MARK: - the Edit affordance on the memo's own screen

    @Test("my own memo offers Edit, opened on the memo as it stands")
    func editModeCarriesTheMemo() throws {
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        let memo = MemoFixture.memo(
            uid: "m7", content: "- [ ] ring the plumber", createdAt: created
        )

        let mode = try #require(MemoDetailPresentation.editMode(for: memo))
        #expect(mode == .edit(uid: "m7", content: "- [ ] ring the plumber", createdAt: created))
    }

    @Test("someone else's memo offers no Edit at all")
    func notMineHasNoEditMode() {
        let memo = MemoFixture.memo(uid: "m8", mine: false)
        #expect(MemoDetailPresentation.editMode(for: memo) == nil)
    }

    @Test("an edit sends a date only when the editor moved it")
    func editedDateIsOnlyEverAMovedOne() {
        let original = Date(timeIntervalSince1970: 1_750_000_000)
        let moved = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(MemoDetailPresentation.editedDate(chosen: original, original: original) == nil)
        #expect(MemoDetailPresentation.editedDate(chosen: nil, original: original) == nil)
        #expect(MemoDetailPresentation.editedDate(chosen: moved, original: original) == moved)
    }
}
