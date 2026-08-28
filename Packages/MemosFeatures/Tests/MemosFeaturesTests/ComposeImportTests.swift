import Foundation
import Testing

@testable import MemosFeatures

/// A picker export that says when it was ENTERED and answers only when the test lets it.
///
/// Both halves are load-bearing here. `waitUntilStarted` is what lets a test decide which
/// selection's load RUNS first — the ordering the runtime is free to pick between two
/// unstructured tasks, and the one the attachment list must not be decided by. `release` decides
/// which of them FINISHES first. Between the two, an overlap that is a coin toss on a phone is a
/// fact in a test.
actor GatedExport {
    private let media: PickedMedia
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ media: PickedMedia) {
        self.media = media
    }

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

    func load() async -> PickedMedia? {
        hasStarted = true
        let waiting = startWaiters
        startWaiters = []
        for waiter in waiting { waiter.resume() }
        if !isReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return media
    }
}

/// Which pick owns the attachment list when two of them are in flight at once.
///
/// The unit under test is the real pipeline object the compose sheet holds; only the picker's
/// export is substituted, because a `PhotosPickerItem` cannot be built outside the picker. The
/// stamping, the fence and the writing are all the production ones.
@MainActor
@Suite("Compose imports")
struct ComposeImportTests {
    static func media(_ name: String) -> PickedMedia {
        PickedMedia(url: URL(filePath: "/tmp/\(name)"), filename: name, mime: "image/heic")
    }

    /// The race the fence exists for, with the interleaving that used to defeat it: the newer
    /// pick's load is the one that starts first, so a stamp taken when a load STARTS numbers the
    /// older pick as the newer one — and then the older pick, arriving whenever it arrives, is
    /// let through onto the screen.
    @Test("the pick made last wins even when its load is the one that started first")
    func theNewestPickWinsWhateverOrderTheLoadsStartIn() async {
        let imports = ComposeImports()
        let older = GatedExport(Self.media("older.heic"))
        let newer = GatedExport(Self.media("newer.heic"))

        // Two picks, back to back, before either has loaded a byte.
        let olderStamp = imports.selected()
        let newerStamp = imports.selected()

        // The second pick's load runs first. Nothing forbids it.
        let newerRun = Task {
            await imports.load(["newer"], stamp: newerStamp) { _ in await newer.load() }
        }
        await newer.waitUntilStarted()
        let olderRun = Task {
            await imports.load(["older"], stamp: olderStamp) { _ in await older.load() }
        }
        await older.waitUntilStarted()

        await older.release()
        #expect(await olderRun.value == false, "the replaced pick wrote the attachment list")
        await newer.release()
        #expect(await newerRun.value == true, "the pick that was made last was refused")

        #expect(imports.attachments.map(\.filename) == ["newer.heic"])
    }

    /// The same overlap in the ordinary order, which must go on working: the older load starts
    /// first and answers first, and is still the one discarded.
    @Test("a replaced pick is discarded, and leaves the spinner the newer one is still owed")
    func aReplacedPickIsDiscardedAndLeavesTheSpinnerRunning() async {
        let imports = ComposeImports()
        let older = GatedExport(Self.media("older.heic"))
        let newer = GatedExport(Self.media("newer.heic"))

        let olderStamp = imports.selected()
        let olderRun = Task {
            await imports.load(["older"], stamp: olderStamp) { _ in await older.load() }
        }
        await older.waitUntilStarted()
        let newerStamp = imports.selected()
        let newerRun = Task {
            await imports.load(["newer"], stamp: newerStamp) { _ in await newer.load() }
        }
        await newer.waitUntilStarted()

        await older.release()
        #expect(await olderRun.value == false)
        #expect(imports.attachments.isEmpty, "the replaced pick was painted")
        #expect(imports.isImporting, "the spinner stopped while the newer pick was still loading")

        await newer.release()
        #expect(await newerRun.value == true)
        #expect(imports.attachments.map(\.filename) == ["newer.heic"])
        #expect(imports.isImporting == false)
    }

    /// "Remove them", tapped while a pick is on its way. The removal has to be final.
    @Test("removing the attachments fences a pick that is still loading")
    func clearingFencesAPickInFlight() async {
        let imports = ComposeImports()
        let export = GatedExport(Self.media("late.heic"))

        let stamp = imports.selected()
        let run = Task {
            await imports.load(["late"], stamp: stamp) { _ in await export.load() }
        }
        await export.waitUntilStarted()

        imports.clear()
        await export.release()

        #expect(await run.value == false, "a removed pick landed anyway")
        #expect(imports.attachments.isEmpty)
        #expect(imports.isImporting == false)
    }

    /// The other half of the same tap: the pick was still QUEUED when it was removed. A stamp
    /// taken when the load starts is taken after the removal, so it outranks it and the removal
    /// silently undoes itself.
    @Test("removing the attachments fences a pick whose load has not started yet")
    func clearingFencesAPickThatHasNotStartedLoading() async {
        let imports = ComposeImports()
        let media = Self.media("queued.heic")

        let stamp = imports.selected()
        imports.clear()
        let run = Task { await imports.load(["queued"], stamp: stamp) { _ in media } }

        #expect(await run.value == false, "a pick removed before it loaded landed anyway")
        #expect(imports.attachments.isEmpty)
        #expect(imports.isImporting == false)
    }

    /// The control every test above is worthless without: a pick nothing has replaced is written
    /// whole — its files and its unreadable ones both.
    @Test("the current pick writes its files and its failures")
    func theCurrentPickWritesFilesAndFailures() async {
        let imports = ComposeImports()
        let stamp = imports.selected()
        #expect(imports.isImporting, "the spinner did not start when the pick landed")

        let kept = Self.media("kept.heic")
        let landed = await imports.load(["ok", "broken"], stamp: stamp) { item in
            item == "ok" ? kept : nil
        }

        #expect(landed)
        #expect(imports.attachments.map(\.filename) == ["kept.heic"])
        #expect(imports.failed == 1)
        #expect(imports.isImporting == false)
    }

    /// Picking again after the first pick has finished REPLACES it. The picker's selection is the
    /// whole selection, not something to add to.
    @Test("a second pick replaces the first rather than adding to it")
    func aSecondPickReplacesTheFirst() async {
        let imports = ComposeImports()
        let first = Self.media("first.heic")
        let second = Self.media("second.heic")

        await imports.load(["first"], stamp: imports.selected()) { _ in first }
        await imports.load(["second"], stamp: imports.selected()) { _ in second }

        #expect(imports.attachments.map(\.filename) == ["second.heic"])
    }

    /// And that replacement is exactly why a capture cannot live in the same list. A photo taken in
    /// the app and then dropped because somebody afterwards chose two from the library is a photo
    /// nobody can take again — a pick can always be made a second time.
    @Test("a capture survives the next pick, which replaces only what was picked")
    func aCaptureSurvivesTheNextPick() async {
        let imports = ComposeImports()
        let shot = Self.media("IMG_20260828-141530.heic")

        await imports.load(["first"], stamp: imports.selected()) { _ in Self.media("first.heic") }
        imports.captured(shot)
        #expect(imports.attachments.map(\.filename) == ["first.heic", "IMG_20260828-141530.heic"])

        await imports.load(["second"], stamp: imports.selected()) { _ in Self.media("second.heic") }

        #expect(
            imports.attachments.map(\.filename) == ["second.heic", "IMG_20260828-141530.heic"],
            "the next pick took the capture with it"
        )
        // "Remove them" still means all of it: a capture is attached to this memo like anything
        // else, and clearing the attachments clears the attachments.
        imports.clear()
        #expect(imports.attachments.isEmpty, "the capture outlived the removal")
    }
}
