import Foundation
import MemosOutbox
import Testing

@testable import MemosFeatures

/// What each picked item says about itself while the memo is being written.
///
/// The subject is the real pipeline object the compose sheet holds; only the picker's export and
/// the capture read are substituted, because a `PhotosPickerItem` cannot be built outside the
/// picker and a capture read would otherwise be a test of ImageIO. The states, the identities, the
/// fences and the ordering are all the production ones.
@MainActor
@Suite("Per-item attachment state")
struct ComposeAttachmentStateTests {
    static let zone = TimeZone(identifier: "Europe/Berlin")!

    static func media(_ name: String) -> PickedMedia {
        PickedMedia(url: URL(filePath: "/tmp/\(name)"), filename: name, mime: "image/heic")
    }

    /// An imports object whose capture read answers whatever the test says, for whichever file.
    static func imports(
        reading: @escaping @MainActor (PickedMedia) async -> CaptureReading = { _ in .empty }
    ) -> ComposeImports {
        ComposeImports(zone: zone, readCapture: reading)
    }

    static func instant(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    // MARK: - the four categories

    @Test(
        "every way a picker load can fail shows the state that belongs to it",
        arguments: [
            (ComposeLoadFailure.transport, "Needs connection"),
            (.iCloudUnavailable, "Needs connection"),
            (.storage, "No room"),
            // Never "needs connection": nobody here knows that, and sending somebody to look for a
            // network that will not help is worse than saying plainly that it did not load.
            (.unknown, "Couldn't load"),
        ]
    )
    func eachCategoryHasItsOwnState(category: ComposeLoadFailure, label: String) async {
        let imports = Self.imports()
        await imports.load(["one"], stamp: imports.selected()) { _ in .failed(category) }

        let item = imports.items[0]
        #expect(item.isFailed)
        #expect(item.media == nil, "a failed item kept a file it never got")
        #expect(item.failure?.tileLabel == label)
        #expect(PickedThumbnail.accessibilityLabel(for: item).contains("Could not be loaded"))
    }

    @Test("the errors the picker actually throws land in the right category")
    func errorsAreClassified() {
        #expect(
            ComposeLoadFailure.category(for: URLError(.notConnectedToInternet)) == .transport)
        #expect(
            ComposeLoadFailure.category(
                for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
                == .storage)
        #expect(
            ComposeLoadFailure.category(
                for: NSError(domain: "CloudPhotoLibraryErrorDomain", code: 1001))
                == .iCloudUnavailable)
        #expect(
            ComposeLoadFailure.category(for: NSError(domain: "SomethingElse", code: 7)) == .unknown)
        // Wrapped, which is how they arrive: the picker hands back what `Transferable` wrapped.
        let wrapped = NSError(
            domain: "TransferableError", code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError])
        #expect(ComposeLoadFailure.category(for: wrapped) == .transport)
    }

    @Test("a failed item stays on the screen as a placeholder with a retry")
    func aFailedItemIsNotDropped() async {
        let imports = Self.imports()
        await imports.load(["ok", "broken"], stamp: imports.selected()) { item in
            item == "ok" ? .file(Self.media("kept.heic")) : .failed(.transport)
        }

        #expect(imports.items.count == 2, "the item that would not load was dropped")
        #expect(imports.attachments.map(\.filename) == ["kept.heic"])
        #expect(imports.failed == 1)
    }

    // MARK: - removing and retrying

    @Test("'Remove them' removes the failed items and nothing else")
    func removeFailedRemovesOnlyTheFailures() async {
        let imports = Self.imports()
        await imports.load(["ok", "broken"], stamp: imports.selected()) { item in
            item == "ok" ? .file(Self.media("kept.heic")) : .failed(.iCloudUnavailable)
        }
        imports.captured(Self.media("IMG_0001.heic"))

        imports.removeFailed()

        #expect(
            imports.attachments.map(\.filename) == ["kept.heic", "IMG_0001.heic"],
            "removing the failures took the successful imports or the camera capture with them")
        #expect(imports.failed == 0)
    }

    @Test("a retry asks for the same item again and keeps its identity")
    func retryKeepsTheIdentity() async {
        let imports = Self.imports()
        let answer = LockedAnswer(.failed(.transport))
        await imports.load(["one"], stamp: imports.selected()) { _ in answer.value }
        let id = imports.items[0].id

        answer.value = .file(Self.media("arrived.heic"))
        await imports.retry(id: id)

        #expect(imports.items.count == 1)
        #expect(imports.items[0].id == id, "the retry replaced the tile instead of filling it")
        #expect(imports.items[0].media?.filename == "arrived.heic")
        #expect(imports.failed == 0)
    }

    @Test("a retry whose item has been removed lands nowhere")
    func retryAfterRemovalLandsNowhere() async {
        let imports = Self.imports()
        await imports.load(["one"], stamp: imports.selected()) { _ in .failed(.transport) }
        let id = imports.items[0].id

        imports.remove(id: id)
        await imports.retry(id: id)

        #expect(imports.items.isEmpty, "a removed item came back through its own retry")
    }

    // MARK: - the identity fence on the capture read

    /// The fence M1 removes. A read is issued for ONE item; if that item is gone when the answer
    /// arrives, the answer is dropped. Without it the answer writes itself into whatever is at that
    /// place in the list — re-dating the memo from a photograph nobody attached.
    @Test("a capture result for an item that has been removed is dropped")
    func aStaleCaptureResultIsDropped() async {
        let gate = ReadGate(CaptureReading(instant: Self.instant("2019-01-01T00:00:00Z")))
        let imports = Self.imports { media in await gate.read(media) }

        await imports.load(["one", "two"], stamp: imports.selected()) { item in
            .file(Self.media("\(item).heic"))
        }
        await gate.waitUntilStarted()
        // Both items go while their reads are in flight, and a new pick takes their place.
        imports.removeFailed()
        imports.remove(id: imports.items[0].id)
        imports.remove(id: imports.items[0].id)
        #expect(imports.items.isEmpty)
        await gate.release()
        await settleTasks()

        #expect(imports.items.isEmpty, "a capture read put back an item that had been removed")
        #expect(imports.autoDate.instant == nil, "a removed item dated the memo")
    }

    @Test("a capture result for a replaced selection is dropped")
    func aCaptureResultFromAReplacedPickIsDropped() async {
        let gate = ReadGate(CaptureReading(instant: Self.instant("2019-01-01T00:00:00Z")))
        let imports = Self.imports { media in
            media.filename == "old.heic" ? await gate.read(media) : .empty
        }

        await imports.load(["old"], stamp: imports.selected()) { _ in .file(Self.media("old.heic"))
        }
        await gate.waitUntilStarted()
        await imports.load(["new"], stamp: imports.selected()) { _ in .file(Self.media("new.heic"))
        }
        await gate.release()
        await settleTasks()

        #expect(imports.attachments.map(\.filename) == ["new.heic"])
        #expect(
            imports.autoDate.instant == nil,
            "a read issued for the pick that was replaced dated this memo")
    }

    // MARK: - the refusal

    /// What M3 removes. A pending read is not a detail: the memo's date AND the order of its
    /// pictures are both decided by it, so a post that goes ahead without it is dated and ordered
    /// by an incomplete set for ever.
    @Test("a post is refused while an item's capture read has not come back")
    func postIsRefusedWhileAReadIsPending() async {
        let gate = ReadGate(.empty)
        let imports = Self.imports { media in await gate.read(media) }
        await imports.load(["one"], stamp: imports.selected()) { _ in .file(Self.media("a.heic")) }
        await gate.waitUntilStarted()

        let refusal = ComposeAttachments.postRefusal(items: imports.items)
        #expect(refusal != nil, "a memo could be posted before its photograph had been read")
        #expect(refusal?.contains("a.heic") == true, "the refusal did not name the item")

        await gate.release()
        await settleTasks()
        // The control: once it has settled, the same list may be posted.
        #expect(ComposeAttachments.postRefusal(items: imports.items) == nil)
    }

    @Test("a post is refused while an item could not be read, and the sentence names it")
    func postIsRefusedWhileAnItemFailed() async {
        let imports = Self.imports()
        await imports.load(["ok", "broken"], stamp: imports.selected()) { item in
            item == "ok" ? .file(Self.media("kept.heic")) : .failed(.transport)
        }
        await settleTasks()

        let refusal = ComposeAttachments.postRefusal(items: imports.items)
        #expect(refusal?.contains("could not be read") == true)
        // The resolved items are still there to post once the failed one is removed.
        imports.removeFailed()
        #expect(ComposeAttachments.postRefusal(items: imports.items) == nil)
        #expect(imports.attachments.map(\.filename) == ["kept.heic"])
    }

    @Test("the Post button is not the guard: an unresolved item still leaves it live")
    func theButtonStaysLive() async {
        let imports = Self.imports()
        await imports.load(["broken"], stamp: imports.selected()) { _ in .failed(.transport) }

        // `canPost` is only "is there a memo here at all" — the refusal is the sentence.
        #expect(
            ComposeAttachments.canPost(text: "words", imported: 0, isBusy: false),
            "a failed item disabled the button, so nobody is told why")
        #expect(ComposeAttachments.postRefusal(items: imports.items) != nil)
    }

    // MARK: - an edit that fails on transport

    @Test("an edit that fails on transport marks its new tiles and keeps everything else")
    func uploadFailureMarksTheTiles() async {
        let imports = Self.imports()
        await imports.load(["one"], stamp: imports.selected()) { _ in .file(Self.media("a.heic")) }
        await settleTasks()

        imports.markUploadFailed(.transport)

        #expect(imports.items[0].failure == .transport)
        #expect(imports.items[0].media != nil, "the file was thrown away when the upload failed")
        #expect(ComposeAttachments.postRefusal(items: imports.items) != nil)

        imports.clearUploadFailures()
        #expect(imports.items[0].failure == nil)
        #expect(ComposeAttachments.postRefusal(items: imports.items) == nil)
    }

    @Test("what a failed save says depends on whether it was sent")
    func theSentencesDifferByCategory() {
        let never = ComposeFailurePresentation.sentence(for: .transport(sent: false))
        let lost = ComposeFailurePresentation.sentence(for: .transport(sent: true))
        #expect(never.contains("nothing has been changed"))
        #expect(lost.contains("could not be confirmed"))
        #expect(!lost.lowercased().contains("nothing was changed"))
        #expect(ComposeFailurePresentation.tileCategory(for: .transport(sent: true)) == .transport)
        // A refusal is about the memo, not about the photographs.
        #expect(ComposeFailurePresentation.tileCategory(for: .rejection) == nil)
    }
}

/// Lets whatever the released reads are doing run to completion.
///
/// The fences are about an answer that must NOT land, and "nothing happened" cannot be waited for
/// — so the tasks are given a generous number of turns instead, and the assertion is made after
/// them. A fence that has been removed fails these tests every time; one that is there cannot be
/// made to fail by giving the scheduler more room.
func settleTasks() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// A picker answer the test can change between attempts.
@MainActor
final class LockedAnswer {
    var value: ComposePickerAnswer
    init(_ value: ComposePickerAnswer) { self.value = value }
}

/// A capture read that says when it has STARTED and answers only when the test lets it.
///
/// Both halves are load-bearing: the fence is about what happens to an answer that arrives after
/// the world has moved, so a test has to be able to put the world's move between the two.
actor ReadGate {
    private let reading: CaptureReading
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ reading: CaptureReading) { self.reading = reading }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiting = releaseWaiters
        releaseWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    func read(_ media: PickedMedia) async -> CaptureReading {
        hasStarted = true
        let waiting = startWaiters
        startWaiters = []
        for waiter in waiting { waiter.resume() }
        if !isReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return reading
    }
}
