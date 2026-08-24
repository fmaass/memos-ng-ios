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
