import Foundation
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
        #expect(ShareComposition.canPost(note: "", items: [.file(file)], failed: 0, isBusy: false))
        #expect(ShareComposition.canPost(note: "a memo", items: [], failed: 0, isBusy: false))
        #expect(!ShareComposition.canPost(note: "   ", items: [], failed: 0, isBusy: false))
    }

    @Test("an item that could not be read blocks the post and is said out loud")
    func refusesWhileSomethingCouldNotBeRead() {
        let file = SharedFile(
            url: URL(fileURLWithPath: "/tmp/x.heic"), filename: "x.heic", mime: "image/heic"
        )
        #expect(
            !ShareComposition.canPost(
                note: "a memo", items: [.file(file)], failed: 1, isBusy: false
            )
        )
        #expect(
            ShareComposition.summary(items: [.file(file)], failed: 1)
                == "1 of 2 could not be read. Share them again."
        )
    }

    @Test("nothing is posted while the share is still being read")
    func refusesWhileBusy() {
        #expect(!ShareComposition.canPost(note: "a memo", items: [], failed: 0, isBusy: true))
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
