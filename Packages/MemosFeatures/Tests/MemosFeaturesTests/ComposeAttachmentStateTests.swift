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

    // MARK: - taking one item off while the pick is still loading

    /// The pick is a loop over the selection, one await per item, and taking one of them off
    /// happens while it is running. What is left has to arrive anyway: an item removed from a
    /// selection that is still coming down is a pick that never finishes otherwise — every later
    /// photograph stuck on its spinner, and a Post the sheet will not let anybody make.
    @Test("removing an item whose file is still coming lets the rest of the pick arrive")
    func aRemovalMidImportLetsTheRestArrive() async {
        let imports = Self.imports()
        let held = GatedExport(Self.media("a.heic"))
        let run = Task {
            await imports.load(["a", "b"], stamp: imports.selected()) { item in
                item == "a" ? await held.load() : .file(Self.media("b.heic"))
            }
        }
        await held.waitUntilStarted()

        // The placeholders are in pick order, so this is the one whose file is suspended.
        imports.remove(id: imports.items[0].id)
        await held.release()
        await run.value
        await settleTasks()

        #expect(
            imports.attachments.map(\.filename) == ["b.heic"],
            "the rest of the pick never arrived: \(imports.items.map(\.label))")
        #expect(!imports.isImporting, "the sheet is still importing a pick that is all here")
    }

    /// The same thing with nothing behind it: the loop's last item is the removed one, and the
    /// spinner it leaves behind is what decides whether the words alone can still be posted.
    @Test("removing the only loading item leaves a memo that can still be posted")
    func removingTheOnlyLoadingItemLeavesAPostableMemo() async {
        let imports = Self.imports()
        let held = GatedExport(Self.media("only.heic"))
        let run = Task {
            await imports.load(["only"], stamp: imports.selected()) { _ in await held.load() }
        }
        await held.waitUntilStarted()

        imports.remove(id: imports.items[0].id)

        // Read HERE, with the discarded export still suspended. That is the moment somebody is
        // looking at: a flag that settles only when a file nobody is waiting for finally arrives
        // is a Post refused for as long as that takes — and the file may never arrive at all.
        #expect(!imports.isImporting, "the composer is importing a pick that has gone")
        #expect(
            ComposeAttachments.canPost(
                text: "just the words then", imported: imports.attachments.count,
                isBusy: imports.isImporting),
            "the words alone could not be posted while the removed picture's export was still out")

        await held.release()
        await run.value
        await settleTasks()

        #expect(!imports.isImporting)
        #expect(
            ComposeAttachments.canPost(
                text: "just the words then", imported: imports.attachments.count,
                isBusy: imports.isImporting),
            "the words alone could not be posted after the one picture was taken off")
    }

    /// A picture taken off the row must not come back through the picker's own binding.
    ///
    /// A selection lands as the WHOLE array, and the item that was removed is still selected in
    /// the picker — so a list rebuilt from that array alone puts the removal straight back the
    /// next time anything is added. Everything else in the selection is imported again, as it
    /// always is: a pick replaces the picked files.
    @Test("a picked file taken off the row does not return with the next selection")
    func aRemovedPickDoesNotReturnWithTheNextSelection() async {
        let imports = Self.imports()
        await imports.load(["a", "b"], stamp: imports.selected()) { item in
            .file(Self.media("\(item).heic"))
        }
        await settleTasks()
        #expect(imports.items.map(\.label) == ["a.heic", "b.heic"], "precondition: both landed")

        imports.remove(id: imports.items[1].id)
        await imports.load(["a", "b", "c"], stamp: imports.selected()) { item in
            .file(Self.media("\(item).heic"))
        }
        await settleTasks()

        #expect(
            imports.items.map(\.label) == ["a.heic", "c.heic"],
            "the removed picture came back with the next pick: \(imports.items.map(\.label))")
    }

    /// The fence the loop change must NARROW and never widen: the answer for a removed item is
    /// dropped, not applied somewhere else and not put back under its own identity.
    @Test("a file that arrives after its item was taken off does not come back")
    func aLateImportForARemovedItemLandsNowhere() async {
        let imports = Self.imports()
        let held = GatedExport(Self.media("gone.heic"))
        let run = Task {
            await imports.load(["gone"], stamp: imports.selected()) { _ in await held.load() }
        }
        await held.waitUntilStarted()
        let removed = imports.items[0].id

        imports.remove(id: removed)
        await held.release()
        await run.value
        await settleTasks()

        #expect(
            !imports.items.contains { $0.id == removed },
            "a removed item came back when its own file arrived")
        #expect(imports.attachments.isEmpty, "a removed item's file was sent anyway")
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

    // MARK: - the tiles arrive at once

    /// E1's first sentence: each picked item renders at once and carries its own state. A list that
    /// appeared only when the slowest file had finished is the modal spinner in another costume.
    @Test("every picked item is on screen before any of them has loaded")
    func theTilesAppearAtOnce() async {
        let gate = AnswerGate(.file(Self.media("first.heic")))
        let imports = Self.imports()
        let stamp = imports.selected()
        let run = Task {
            await imports.load(["one", "two", "three"], stamp: stamp) { _ in await gate.answer() }
        }
        await gate.waitUntilAsked()

        #expect(imports.items.count == 3, "the tiles waited for the files")
        #expect(imports.items.filter(\.isLoading).count == 3)
        #expect(imports.isImporting)
        // And a post is refused while they are on their way, naming one of them.
        let refusal = ComposeAttachments.postRefusal(items: imports.items)
        #expect(refusal?.contains("still loading") == true, "refusal was: \(refusal ?? "nil")")

        await gate.release()
        _ = await run.value
        await settleTasks()
        #expect(imports.attachments.count == 3)
        #expect(ComposeAttachments.postRefusal(items: imports.items) == nil)
    }

    /// R3's rule, stated: a second retry of one item is REFUSED while the first is on the wire.
    /// Two overlapping imports would race to write one tile, and the older answer landing last
    /// would put a failure back over a success.
    @Test("a second retry of the same item while one is in flight is refused")
    func overlappingRetriesAreRefused() async {
        let imports = Self.imports()
        let gate = AnswerGate(.file(Self.media("arrived.heic")))
        let calls = Counted()
        // The first call is the pick, which fails; every call after it is a RETRY, and the retries
        // are the ones the gate holds.
        let loader: @MainActor (String) async -> ComposePickerAnswer = { _ in
            calls.increment()
            if calls.count == 1 { return .failed(.transport) }
            return await gate.answer()
        }
        await imports.load(["one"], stamp: imports.selected(), using: loader)
        let id = imports.items[0].id

        let first = Task { await imports.retry(id: id) }
        await gate.waitUntilAsked()
        #expect(calls.count == 2)
        // The second tap, while the first is still out there.
        await imports.retry(id: id)
        #expect(calls.count == 2, "the overlapping retry started a second import of one tile")

        await gate.release()
        await first.value
        #expect(imports.items[0].media?.filename == "arrived.heic")
        #expect(imports.items[0].id == id, "the retry replaced the tile instead of filling it")
        // Once it is over, the item can be asked for again.
        await imports.retry(id: id)
        #expect(calls.count == 3)
    }

    /// A retry is asked at a tap and does its writing afterwards, so it can still be waiting when
    /// the save is claimed. Landing then, it would put a different file under an identity the
    /// upload is already carrying — or settle the tile failed, which would also put "Remove them"
    /// back on a sheet whose list is fixed. So the refusal is where the writing is, not at the
    /// tap: what a tap knows is true at the tap.
    @Test("a retry asked while a save is on the wire writes nothing and asks for nothing")
    func aRetryDuringASaveIsRefused() async {
        let imports = Self.imports()
        let calls = Counted()
        let loader: @MainActor (String) async -> ComposePickerAnswer = { _ in
            calls.increment()
            return calls.count == 1 ? .failed(.transport) : .file(Self.media("arrived.heic"))
        }
        await imports.load(["one"], stamp: imports.selected(), using: loader)
        let id = imports.items[0].id
        #expect(imports.items[0].isFailed, "the item this is about did not fail")

        imports.beginSubmission()
        await imports.retry(id: id)

        #expect(calls.count == 1, "the refused retry asked the picker for the file again")
        #expect(imports.items[0].isFailed, "the refused retry moved the tile out of its failure")
        #expect(imports.items[0].media == nil, "the refused retry put a file under the identity")

        // And nothing is left claimed by the refusal: the same tap works once the save is back.
        imports.endSubmission()
        await imports.retry(id: id)

        #expect(calls.count == 2, "the refusal outlived the save it was made for")
        #expect(imports.items[0].media?.filename == "arrived.heic")
    }

    /// R8: the tile's own load is keyed on the FILE, because the identity deliberately survives a
    /// retry — keyed on that, a recovered item would keep the placeholder it had while it failed.
    @Test("a recovered item's tile reloads, because the key is the file and not the identity")
    func theThumbnailKeyFollowsTheFile() async {
        let imports = Self.imports()
        let calls = Counted()
        let loader: @MainActor (String) async -> ComposePickerAnswer = { _ in
            calls.increment()
            return calls.count == 1 ? .failed(.transport) : .file(Self.media("arrived.heic"))
        }
        await imports.load(["one"], stamp: imports.selected(), using: loader)
        let id = imports.items[0].id
        let whileFailed = PickedThumbnail.thumbnailKey(for: imports.items[0])

        await imports.retry(id: id)

        let afterRetry = PickedThumbnail.thumbnailKey(for: imports.items[0])
        #expect(imports.items[0].id == id, "the identity did not survive the retry")
        #expect(whileFailed == nil, "a tile with no file had something to load")
        #expect(afterRetry != nil, "the recovered tile has nothing to load")
        #expect(afterRetry != whileFailed)
    }

    /// The one thing somebody can do about an upload that failed is to try it again — so the marks
    /// the last attempt left must be cleared BEFORE the next attempt is judged, or the tiles it
    /// marked refuse the very save they are asking for.
    @Test("a save can be tried again after it failed on transport")
    func aFailedSaveCanBeTriedAgain() async {
        let imports = Self.imports()
        await imports.load(["one"], stamp: imports.selected()) { _ in .file(Self.media("a.heic")) }
        await settleTasks()
        imports.markUploadFailed(.transport)

        // Judged with the previous attempt's marks still on, this is refused and the person is
        // stuck with a memo they cannot save and cannot fix.
        #expect(ComposeAttachments.postRefusal(items: imports.items) != nil)
        // The attempt itself clears them first, so it goes.
        #expect(imports.beginPostAttempt() == nil, "a failed save could never be tried again")
        #expect(imports.items[0].failure == nil)
    }

    /// A photograph taken in this app cannot be asked for again — there is no picker to ask — but
    /// its file is already here, so "Try again" has to mean something: clear the mark the upload
    /// left and read it again.
    @Test("a camera capture whose upload failed can be retried like anything else")
    func aCameraCaptureCanBeRetried() async {
        let imports = Self.imports()
        imports.captured(Self.media("IMG_0001.heic"))
        await settleTasks()
        imports.markUploadFailed(.transport)
        #expect(imports.items[0].failure == .transport)

        await imports.retry(id: imports.items[0].id)
        await settleTasks()

        #expect(imports.items[0].failure == nil, "the camera tile's retry did nothing at all")
        #expect(imports.items[0].isFailed == false)
        #expect(imports.items[0].media?.filename == "IMG_0001.heic")
        #expect(ComposeAttachments.postRefusal(items: imports.items) == nil)
    }

    @Test("what a failed save says depends on whether it was sent")
    func theSentencesDifferByCategory() {
        let never = ComposeFailurePresentation.sentence(for: .transport(sent: false))
        let lost = ComposeFailurePresentation.sentence(for: .transport(sent: true))
        #expect(never.contains("nothing has been changed"))
        #expect(lost.contains("could not be confirmed"))
        #expect(!lost.lowercased().contains("nothing was changed"))
        #expect(
            !ComposeFailurePresentation.sentence(for: .rejection)
                .lowercased().contains("nothing was changed"),
            "a rejection can be a server fault AFTER the edit was committed"
        )
        #expect(ComposeFailurePresentation.tileCategory(for: .transport(sent: true)) == .transport)
        // A refusal is about the memo, not about the photographs.
        #expect(ComposeFailurePresentation.tileCategory(for: .rejection) == nil)
    }

    /// A server that broke on a save and a server that refused one are opposite facts about the
    /// memo, so they may not share a sentence: one of them leaves the words possibly saved and the
    /// other leaves them certainly not.
    @Test("a server that broke on a save does not borrow the sentence for one it refused")
    func aServerFaultHasASentenceOfItsOwn() {
        let broke = ComposeFailurePresentation.sentence(for: .serverFailure)
        #expect(broke != ComposeFailurePresentation.sentence(for: .rejection))
        #expect(!broke.lowercased().contains("nothing was changed"))
        // And it says the retry is safe, which is the part somebody can act on: the save goes out
        // under the same edit key and the server replays it rather than applying it twice.
        #expect(broke.lowercased().contains("try again"))
    }

    /// The files went up fine and so did the network; what broke was the server. Marking the
    /// photographs would send somebody looking for a connection that was never the problem.
    @Test("a server fault is not the photographs' business")
    func aServerFaultLeavesTheTilesAlone() {
        #expect(ComposeFailurePresentation.tileCategory(for: .serverFailure) == nil)
    }

    /// A tile asked for again is a tile loading, and the composer is importing for exactly as long
    /// as one of them is — whatever else leaves the row while that ask is out.
    ///
    /// The row is not still between the two: the picture that arrived first can be taken off while
    /// the failed one is being fetched again, and the ask that is still out is then the only thing
    /// holding Post. A flag left standing after it lands is a Post refused for the rest of the
    /// sheet's life, with nothing on the screen to say why.
    @Test("a retry still out keeps the composer importing until it lands")
    func aHeldRetryKeepsTheComposerImporting() async {
        let imports = Self.imports()
        let gate = RetryGate(Self.media("a.heic"))
        await imports.load(["a", "b"], stamp: imports.selected()) { item in
            item == "a" ? await gate.answer() : .file(Self.media("b.heic"))
        }
        await settleTasks()

        let failed = imports.items[0].id
        let arrived = imports.items[1].id
        #expect(imports.items[0].isFailed, "the first file was supposed to be the one that failed")
        #expect(!imports.isImporting, "the pick is all in and the composer is still importing")

        let retry = Task { await imports.retry(id: failed) }
        await gate.waitUntilRetryStarted()
        await settleTasks()
        #expect(imports.isImporting, "a tile is on its spinner and the composer is not importing")

        imports.remove(id: arrived)
        #expect(imports.isImporting, "the retry is still out and the composer stopped importing")

        await gate.release()
        await retry.value
        await settleTasks()

        #expect(!imports.isImporting, "the retry landed and the composer is importing still")
        #expect(
            ComposeAttachments.canPost(
                text: "", imported: imports.attachments.count, isBusy: imports.isImporting),
            "the picture is here and the memo cannot be posted")
    }
}

/// A picker export that fails the first time it is asked and holds the second.
///
/// The second ask is the retry, and holding it open is what lets a test change the row while one
/// tile is loading and the others are not.
actor RetryGate {
    private let media: PickedMedia
    private var asks = 0
    private var retryStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ media: PickedMedia) { self.media = media }

    func waitUntilRetryStarted() async {
        if retryStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiting = releaseWaiters
        releaseWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    func answer() async -> ComposePickerAnswer {
        asks += 1
        if asks == 1 { return .failed(.transport) }
        retryStarted = true
        let waiting = startWaiters
        startWaiters = []
        for waiter in waiting { waiter.resume() }
        if !isReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .file(media)
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

/// A picker answer that says when it has been ASKED for and answers only when the test lets it.
actor AnswerGate {
    private let answerValue: ComposePickerAnswer
    private var asked = false
    private var askWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ answer: ComposePickerAnswer) { self.answerValue = answer }

    func waitUntilAsked() async {
        if asked { return }
        await withCheckedContinuation { askWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func answer() async -> ComposePickerAnswer {
        asked = true
        let waiters = askWaiters
        askWaiters = []
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return answerValue
    }
}

/// How many times something was asked for.
@MainActor
final class Counted {
    private(set) var count = 0
    func increment() { count += 1 }
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
