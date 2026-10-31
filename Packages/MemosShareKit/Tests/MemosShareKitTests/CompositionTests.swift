import Foundation
import MemosOutbox
import MemosShareKit
import Testing

@Suite("What a share becomes as words")
struct CompositionTests {
    private let link = URL(string: "https://example.invalid/an-article")!

    @Test("a note and a shared link become one memo, the note first")
    func mergesNoteAndLink() {
        let content = ShareComposition.content(note: "  worth reading  ", items: [.link(link)])
        #expect(content == "worth reading\n\nhttps://example.invalid/an-article")
    }

    @Test("a browser hands over the title and the address, and both are kept")
    func keepsTitleAndAddress() {
        let content = ShareComposition.content(
            note: "", items: [.text("An Article"), .link(link)]
        )
        #expect(content == "An Article\n\nhttps://example.invalid/an-article")
    }

    @Test("what the note already says is not repeated underneath it")
    func doesNotRepeatWhatTheNoteSays() {
        let content = ShareComposition.content(
            note: "https://example.invalid/an-article is worth reading",
            items: [.link(link)]
        )
        #expect(content == "https://example.invalid/an-article is worth reading")
    }

    @Test("a share with only files is postable; an empty one is not")
    func postableWhenThereIsSomething() {
        let file = SharedFile(
            url: URL(fileURLWithPath: "/tmp/x.heic"), filename: "x.heic", mime: "image/heic"
        )
        #expect(
            ShareComposition.canPost(
                for: .member, note: "", items: [.file(file)], failed: 0, isBusy: false
            )
        )
        #expect(
            ShareComposition.canPost(
                for: .member, note: "a memo", items: [], failed: 0, isBusy: false
            )
        )
        #expect(
            !ShareComposition.canPost(
                for: .member, note: "   ", items: [], failed: 0, isBusy: false
            )
        )
    }

    @Test("an item that could not be read blocks the post and is said out loud")
    func refusesWhileSomethingCouldNotBeRead() {
        let file = SharedFile(
            url: URL(fileURLWithPath: "/tmp/x.heic"), filename: "x.heic", mime: "image/heic"
        )
        #expect(
            !ShareComposition.canPost(
                for: .member, note: "a memo", items: [.file(file)], failed: 1, isBusy: false
            )
        )
        #expect(
            ShareComposition.summary(items: [.file(file)], failed: 1)
                == "1 of 2 could not be read. Share them again."
        )
    }

    @Test("a share where NOTHING could be read still says so")
    func speaksWhenEverythingFailed() {
        // There are no items left to hang the message off, which is exactly when a silent sheet
        // would refuse to post and never explain why.
        #expect(
            ShareComposition.summary(items: [], failed: 2)
                == "2 of 2 could not be read. Share them again."
        )
        #expect(
            !ShareComposition.canPost(for: .member, note: "", items: [], failed: 2, isBusy: false)
        )
        #expect(
            !ShareComposition.canPost(
                for: .member, note: "a note", items: [], failed: 2, isBusy: false
            ),
            "words of one's own do not make up for the photo that did not arrive"
        )
    }

    /// One share, as the sheet would hold it, and whether Post should be offered for it.
    struct PostCase: Sendable, CustomTestStringConvertible {
        let kind: CredentialKind
        let note: String
        let items: [SharedItem]
        var failed = 0
        var isBusy = false
        let postable: Bool
        let testDescription: String
    }

    static let photo = SharedItem.file(
        SharedFile(
            url: URL(fileURLWithPath: "/tmp/x.heic"), filename: "x.heic", mime: "image/heic"
        )
    )
    static let article = SharedItem.link(URL(string: "https://example.invalid/a")!)

    // Mutation that turns it red: drop the guest clause in `canPost`, so a guest share with words
    // and no file is postable again.
    @Test(
        "a trip takes files: a guest share posts with a photo, never with words alone",
        arguments: [
            PostCase(
                kind: .guest, note: "", items: [photo], postable: true,
                testDescription: "guest, a photo"),
            PostCase(
                kind: .guest, note: "at the lake", items: [photo], postable: true,
                testDescription: "guest, a photo and a note"),
            PostCase(
                kind: .guest, note: "", items: [.text("a caption")], postable: false,
                testDescription: "guest, shared text only"),
            PostCase(
                kind: .guest, note: "", items: [article], postable: false,
                testDescription: "guest, a link only"),
            PostCase(
                kind: .guest, note: "only words", items: [], postable: false,
                testDescription: "guest, a typed note only"),
            PostCase(
                kind: .guest, note: "", items: [], postable: false,
                testDescription: "guest, nothing"),
            PostCase(
                kind: .guest, note: "", items: [photo], failed: 1, postable: false,
                testDescription: "guest, a photo and one that failed"),
            PostCase(
                kind: .guest, note: "", items: [photo], isBusy: true, postable: false,
                testDescription: "guest, a photo while busy"),
            PostCase(
                kind: .member, note: "", items: [.text("a caption")], postable: true,
                testDescription: "member, shared text only"),
            PostCase(
                kind: .member, note: "", items: [article], postable: true,
                testDescription: "member, a link only"),
            PostCase(
                kind: .member, note: "", items: [photo], postable: true,
                testDescription: "member, a photo"),
            PostCase(
                kind: .member, note: "a memo", items: [photo], failed: 1, postable: false,
                testDescription: "member, one that failed"),
            PostCase(
                kind: .member, note: "a memo", items: [], isBusy: true, postable: false,
                testDescription: "member, while busy"),
        ])
    func postableByRoute(_ share: PostCase) {
        #expect(
            ShareComposition.canPost(
                for: share.kind, note: share.note, items: share.items, failed: share.failed,
                isBusy: share.isBusy
            ) == share.postable
        )
    }

    @Test("nothing is posted while the share is still being read")
    func refusesWhileBusy() {
        #expect(
            !ShareComposition.canPost(
                for: .member, note: "a memo", items: [], failed: 0, isBusy: true
            )
        )
    }

    @Test("the summary counts files, and says nothing about words")
    func summarisesFiles() {
        let first = SharedFile(
            url: URL(fileURLWithPath: "/tmp/a.heic"), filename: "a.heic", mime: "image/heic"
        )
        let second = SharedFile(
            url: URL(fileURLWithPath: "/tmp/b.mov"), filename: "b.mov", mime: "video/quicktime"
        )
        #expect(ShareComposition.summary(items: [.file(first)], failed: 0) == "1 file attached")
        #expect(
            ShareComposition.summary(items: [.file(first), .file(second)], failed: 0)
                == "2 files attached"
        )
        #expect(ShareComposition.summary(items: [.text("a note")], failed: 0) == nil)
    }
}
