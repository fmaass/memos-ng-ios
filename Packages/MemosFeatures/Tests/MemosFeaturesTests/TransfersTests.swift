import Foundation
import MemosOutbox
import Testing

@testable import MemosFeatures

nonisolated private let start = Date(timeIntervalSince1970: 1_760_000_000)
nonisolated private let server = URL(string: "https://memos.example.invalid")!

private func file(_ size: Int64, confirmed: Int64 = 0, uid: String? = nil) -> OutboxFile {
    OutboxFile(
        relativePath: "a.heic", filename: "a.heic", mime: "image/heic", byteSize: size,
        uploadUID: uid, bytesConfirmed: confirmed)
}

private func job(
    _ state: JobState, hold: HoldReason? = nil, wait: WaitReason? = nil,
    files: [OutboxFile] = [file(100)], unanswered: Date? = nil, attempts: Int = 0
) -> UploadJob {
    UploadJob(
        content: "Day at the lake", capturedAt: start, files: files,
        binding: AccountBinding(serverBaseURL: server, ownerSubject: "alice"),
        state: state, holdReason: hold, waitReason: wait, attemptCount: attempts,
        editUnansweredSince: unanswered)
}

@MainActor
private func ledger(_ jobs: [UploadJob]) -> TransferLedger {
    let ledger = TransferLedger(clock: { start })
    ledger.apply(jobs, generation: 1)
    return ledger
}

/// The first row's reason and action for one capture.
@MainActor
private func row(
    _ one: UploadJob, verdict: UploadVerdict = .permitted, progress: [UUID: Date] = [:]
) -> TransfersRow? {
    TransfersPresentation.sections(
        for: ledger([one]), now: start, lastProgressAt: progress, verdict: verdict
    ).first?.rows.first
}

@MainActor
@Suite("Transfers: the switch, the strip and the sheet's rows")
struct TransfersPresentationTests {
    @Test("the transfers switch is on unless the pane says off")
    func flagDefaultsOn() throws {
        let name = "transfers.flag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        #expect(TransfersFlag.isEnabled(defaults))
        defaults.set(false, forKey: TransfersFlag.toggleKey)
        #expect(TransfersFlag.isEnabled(defaults) == false)
        defaults.set(true, forKey: TransfersFlag.toggleKey)
        #expect(TransfersFlag.isEnabled(defaults))
    }

    @Test("the strip says sent of total, bytes left and the time, or paused, or no time")
    func stripLine() {
        let bytes = TransfersPresentation.byteString(1_400_000_000)
        let summary = TransferSummary(
            jobs: 2, filesDone: 12, filesTotal: 30, bytesConfirmed: 100,
            bytesTotal: 1_400_000_100)
        #expect(
            TransfersPresentation.stripLine(summary: summary, eta: .remaining(330))
                == "12 of 30 sent · \(bytes) left · about 6 min")
        #expect(
            TransfersPresentation.stripLine(summary: summary, eta: .paused)
                == "12 of 30 sent · \(bytes) left · paused")
        #expect(
            TransfersPresentation.stripLine(summary: summary, eta: .unknown)
                == "12 of 30 sent · \(bytes) left")
        let finished = TransferSummary(
            jobs: 1, filesDone: 3, filesTotal: 3, bytesConfirmed: 9, bytesTotal: 9)
        #expect(
            TransfersPresentation.stripLine(summary: finished, eta: .remaining(0))
                == "3 of 3 sent")
        let none = TransferSummary(
            jobs: 0, filesDone: 0, filesTotal: 0, bytesConfirmed: 0, bytesTotal: 0)
        #expect(
            TransfersPresentation.stripLine(summary: none, eta: .unknown)
                == TransfersPresentation.nothingLeft)
    }

    @Test("a held capture is named on the strip, and its bytes on the server read sent")
    func stripNamesAHeldCapture() {
        // Every byte on the server, the create held: never "0 of 1 sent" with nothing left.
        let sent = job(
            .held, hold: .signInRequired, files: [file(100, confirmed: 100, uid: "u")])
        #expect(
            TransfersPresentation.stripLine(for: ledger([sent]), now: start)
                == "1 of 1 sent · 1 held")
        // Nothing sent yet: still named, beside what is left.
        let stuck = job(.held, hold: .tooLarge)
        #expect(
            TransfersPresentation.stripLine(for: ledger([stuck, job(.uploading)]), now: start)
                == "0 of 2 sent · 1 held · \(TransfersPresentation.byteString(200)) left")
        // A file with no bytes of its own (an item still in Photos) is not sent by being empty.
        let empty = job(.held, hold: .tooLarge, files: [file(0)])
        #expect(
            TransfersPresentation.stripLine(for: ledger([empty]), now: start)
                == "0 of 1 sent · 1 held")
        // No hold, no word for one.
        #expect(
            TransfersPresentation.stripLine(for: ledger([job(.uploading)]), now: start)
                == "0 of 1 sent · \(TransfersPresentation.byteString(100)) left")
    }

    @Test("the strip's row changes only at the top of the list, so the reader is not moved")
    func stripPlaceKeepsTheReadersPlace() {
        var place = TransfersStripPlace()
        place.want(true)
        #expect(place.shown)
        // Read further down: the strip going would pull everything up by its height.
        place.scrolled(atTop: false)
        place.want(false)
        #expect(place.shown)
        place.scrolled(atTop: true)
        #expect(place.shown == false)
        // Arriving while the reader is down the list waits for them to come back up.
        place.scrolled(atTop: false)
        place.want(true)
        #expect(place.shown == false)
        #expect(place.jumpTarget(notice: "notice", strip: "strip") == "notice")
        place.scrolled(atTop: true)
        #expect(place.shown)
        // A jump lands on the strip, not on the notice with the strip just above the view.
        #expect(place.jumpTarget(notice: "notice", strip: "strip") == "strip")
        // A reading that changes nothing about the top changes nothing.
        place.scrolled(atTop: true)
        #expect(place.shown)
        // The ledger and the scroll may report in either order; both end in the same place.
        var ledgerFirst = place
        ledgerFirst.scrolled(atTop: false)
        ledgerFirst.want(false)
        ledgerFirst.scrolled(atTop: true)
        var scrollFirst = place
        scrollFirst.scrolled(atTop: false)
        scrollFirst.scrolled(atTop: true)
        scrollFirst.want(false)
        #expect(ledgerFirst == scrollFirst)
        #expect(ledgerFirst.shown == false)
    }

    @Test("at the top means at rest there or pulled past it, tighter than the paging trigger")
    func stripPlaceTop() {
        #expect(TransfersStripPlace.isAtTop(contentOffsetY: -100, topInset: 100))
        #expect(TransfersStripPlace.isAtTop(contentOffsetY: -160, topInset: 100))
        #expect(TransfersStripPlace.isAtTop(contentOffsetY: -99, topInset: 100))
        #expect(TransfersStripPlace.isAtTop(contentOffsetY: -98, topInset: 100) == false)
        // Twenty points down still pages the list above; it would still move the reader.
        #expect(TimelineTopWatch.isAtTop(contentOffsetY: -80, topInset: 100))
        #expect(TransfersStripPlace.isAtTop(contentOffsetY: -80, topInset: 100) == false)
    }

    @Test("a fix's move belongs to its sheet: made at the dismissal, or at once once it has gone")
    func handOffBelongsToItsPresentation() {
        var handOff = TransfersHandOff<TimelineView.TransfersFollowUp>()
        handOff.opened()
        #expect(handOff.leave(.signIn) == nil)
        #expect(handOff.dismissed() == .signIn)
        #expect(handOff.dismissed() == nil)
        // Dismissed while the fix was out: its move is made when it returns, not left for the
        // next sheet's dismissal to open over whatever that one was for.
        handOff.opened()
        #expect(handOff.dismissed() == nil)
        #expect(handOff.leave(.signIn) == .signIn)
        handOff.opened()
        #expect(handOff.dismissed() == nil)
        // Dismissed and opened again while the fix was out: the open sheet is the one closed for
        // it (the timeline closes it when `leave` keeps the move), and its dismissal makes it.
        handOff.opened()
        #expect(handOff.leave(.signIn) == nil)
        #expect(handOff.dismissed() == .signIn)
    }

    @Test("an open sheet wakes when a row's stall threshold passes, with no ledger change")
    func sheetWakesAtTheStall() {
        let moving = job(.uploading)
        let queue = ledger([moving])
        let progress = [moving.id: start]
        let now = start.addingTimeInterval(10)
        let wake = TransfersPresentation.sheetWake(
            for: queue, lastProgressAt: progress, after: now)
        #expect(wake == start.addingTimeInterval(PendingMemoPresentation.stallInterval))
        let before = TransfersPresentation.sections(
            for: queue, now: now, lastProgressAt: progress, verdict: .permitted)
        #expect(before.first?.rows.first?.reason == nil)
        let woken = TransfersPresentation.sections(
            for: queue, now: wake ?? now, lastProgressAt: progress, verdict: .permitted)
        #expect(woken.first?.rows.first?.reason == PendingMemoPresentation.noProgressConfirmed)
        // Said once: nothing after that instant changes the sentence on its own.
        #expect(
            TransfersPresentation.sheetWake(
                for: queue, lastProgressAt: progress, after: wake ?? now) == nil)
    }

    @Test("the ETA is worded under a minute, in minutes, then in hours")
    func etaWording() {
        #expect(TransfersPresentation.etaText(.unknown) == nil)
        #expect(TransfersPresentation.etaText(.paused) == "paused")
        #expect(TransfersPresentation.etaText(.remaining(59)) == "under a minute")
        #expect(TransfersPresentation.etaText(.remaining(60)) == "about 1 min")
        #expect(TransfersPresentation.etaText(.remaining(61)) == "about 2 min")
        #expect(TransfersPresentation.etaText(.remaining(3600)) == "about 1 h")
        #expect(TransfersPresentation.etaText(.remaining(3720)) == "about 1 h 2 min")
    }

    @Test("the strip is there while a capture is queued and gone thirty seconds after it lands")
    func stripFollowsTheLedger() {
        var now = start
        let ledger = TransferLedger(clock: { start })
        #expect(TransfersPresentation.stripLine(for: ledger, now: now) == nil)
        ledger.apply([job(.uploading)], generation: 1)
        #expect(TransfersPresentation.stripLine(for: ledger, now: now) != nil)
        ledger.apply([], generation: 2)
        now = start.addingTimeInterval(29)
        #expect(
            TransfersPresentation.stripLine(for: ledger, now: now)
                == TransfersPresentation.nothingLeft)
        now = start.addingTimeInterval(30)
        #expect(TransfersPresentation.stripLine(for: ledger, now: now) == nil)
    }

    @Test("each stopped row's reason is the pending row's own sentence, and its one fix")
    func reasonsAndFixes() {
        let held = job(.held, hold: .tooLarge)
        #expect(row(held)?.reason == PendingMemoPresentation.status(for: held))
        #expect(row(held)?.action == .remove)
        // Remove is never offered beside a change the server has not answered.
        #expect(row(job(.held, hold: .tooLarge, unanswered: start))?.action == .retryNow)
        #expect(row(job(.held, hold: .signInRequired))?.action == .signIn)
        #expect(row(job(.held, hold: .accountMismatch))?.action == .switchAccount)
        // Every byte on the server, the create held: the hold's reason and fix, a full ring.
        let sent = row(
            job(.held, hold: .signInRequired, files: [file(100, confirmed: 100, uid: "u")]))
        #expect(sent?.reason == "Sign in again to send this memo")
        #expect(sent?.action == .signIn)
        #expect(sent?.fraction == 1)
        #expect(TransfersAction.switchAccount.title == "Sign out and switch account")
        #expect(row(job(.held, hold: .serverRefused))?.action == .retryNow)
        #expect(row(job(.held, hold: .unreadableManifest))?.action == .remove)
        #expect(row(job(.held, hold: .editIncomplete))?.action == .reopen)
        #expect(row(job(.held, hold: .editIncomplete, unanswered: start))?.action == .retryNow)
        let refused = UploadVerdict.refused(.cellularWhileMobileDataOff)
        let waiting = job(.waiting, wait: .homeNetwork)
        #expect(
            row(waiting, verdict: refused)?.reason
                == PendingMemoPresentation.refusal(.cellularWhileMobileDataOff))
        #expect(row(waiting, verdict: refused)?.action == .useMobileData)
        #expect(
            row(waiting, verdict: .refused(.expensiveWhileMobileDataOff))?.action
                == .useMobileData)
        #expect(row(waiting, verdict: .refused(.noPath))?.action == nil)
        #expect(row(waiting, verdict: .refused(.lowDataMode))?.action == nil)
        let retrying = job(.waiting, wait: .retrying, attempts: 2)
        #expect(row(retrying)?.reason == PendingMemoPresentation.retrying)
        #expect(row(retrying)?.action == .retryNow)
        // Never tried yet: it says why it waits and offers nothing.
        #expect(row(job(.waiting))?.reason == PendingMemoPresentation.status(for: job(.waiting)))
        #expect(row(job(.waiting))?.action == nil)
    }

    @Test("a capture a video rule holds offers Use mobile data for this one, once, and only then")
    func videoWaitOffersTheOverride() {
        let video = OutboxFile(
            relativePath: "v.mov", filename: "v.mov", mime: "video/quicktime",
            byteSize: UploadNetworkPolicy.mobileVideoLimit + 1)
        let large = job(.waiting, wait: .videoOverMobileLimit, files: [video])
        #expect(row(large)?.reason == "Waiting for Wi-Fi (video over 200 MB)")
        #expect(row(large)?.action == .useMobileDataForThisOne)
        #expect(TransfersAction.useMobileDataForThisOne.title == "Use mobile data for this one")
        // Under Never, the same offer beside the sentence that names the setting.
        let never = job(.waiting, wait: .videoOnWiFiOnly, files: [video])
        #expect(row(never)?.action == .useMobileDataForThisOne)
        // Tried before: still the override, not a retry that would only wait again.
        let tried = job(.waiting, wait: .videoOverMobileLimit, files: [video], attempts: 2)
        #expect(row(tried)?.action == .useMobileDataForThisOne)
        // Already let go: not offered a second time.
        var released = large
        released.videoOverMobileAllowed = true
        #expect(row(released)?.action != .useMobileDataForThisOne)
        // Any other wait never offers it.
        #expect(row(job(.waiting, wait: .homeNetwork, files: [video]))?.action == nil)
        // Mobile data off outranks it: the switch is the fix, not this capture's exception.
        #expect(
            row(large, verdict: .refused(.cellularWhileMobileDataOff))?.action == .useMobileData)
    }

    @Test("a moving file says nothing; a stalled or refused one says why and offers its fix")
    func uploadingRows() {
        let moving = job(.uploading)
        #expect(row(moving)?.reason == nil)
        #expect(row(moving)?.action == nil)
        let stalled = [moving.id: start.addingTimeInterval(-PendingMemoPresentation.stallInterval)]
        #expect(
            row(moving, progress: stalled)?.reason == PendingMemoPresentation.noProgressConfirmed)
        #expect(row(moving, progress: stalled)?.action == .retryNow)
        let recent = [moving.id: start.addingTimeInterval(-10)]
        #expect(row(moving, progress: recent)?.reason == nil)
        let refused = UploadVerdict.refused(.cellularWhileMobileDataOff)
        #expect(row(moving, verdict: refused)?.action == .useMobileData)
        let done = job(.uploading, files: [file(100, confirmed: 100, uid: "u")])
        #expect(row(done, verdict: refused)?.reason == nil)
        #expect(row(done, verdict: refused)?.action == nil)
        #expect(row(done)?.fraction == 1)
    }

    @Test("a file spacing out its own retry inside a moving capture says it is retrying")
    func fileRetrying() {
        var spaced = file(100, confirmed: 10, uid: "u")
        spaced.nextAttemptAt = start.addingTimeInterval(8)
        let one = job(.uploading, files: [spaced])
        #expect(row(one)?.reason == PendingMemoPresentation.retrying)
        #expect(row(one)?.action == .retryNow)
    }

    @Test("the sheet has a section per capture, newest first, and a row per file with its bytes")
    func sectionsPerCapture() {
        var older = job(.uploading, files: [file(1000, confirmed: 250, uid: "u"), file(10)])
        older.capturedAt = start.addingTimeInterval(-60)
        let newer = job(.uploading)
        let sections = TransfersPresentation.sections(
            for: ledger([older, newer]), now: start, lastProgressAt: [:], verdict: .permitted)
        #expect(sections.map(\.id) == [newer.id, older.id])
        #expect(sections[1].rows.count == 2)
        #expect(sections[1].title == "Day at the lake")
        #expect(sections[1].rows[0].fraction == 0.25)
        #expect(
            sections[1].rows[0].bytes
                == "\(TransfersPresentation.byteString(250)) of "
                + TransfersPresentation.byteString(1000))
        #expect(sections[1].rows.allSatisfy { $0.jobID == older.id })
    }
}

// MARK: - The fixes, through the real outbox

private struct SignedIn: OutboxCredentialsProviding {
    func currentCredentials() async -> OutboxCredentials? {
        OutboxCredentials(serverBaseURL: server, ownerSubject: "alice", token: "pat-token")
    }
    func isCurrent(_ credentials: OutboxCredentials) -> Bool { true }
    func stillCurrent(epoch: Int) -> Bool { true }
}

/// Nothing is ever sent: every request is refused as a server error, which a drain backs off from.
private struct RefusingHTTP: OutboxHTTPPerforming {
    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        OutboxHTTPResponse(statusCode: 500)
    }
}

private struct NoChunks: OutboxChunkScheduling {
    func inFlight() async -> [OutboxTaskIdentity] { [] }
    func upload(
        _ request: URLRequest, fromFile file: URL, identity: OutboxTaskIdentity,
        under authority: SendAuthority, issuedUnder epoch: Int
    ) async {}
    func cancel(_ identities: [OutboxTaskIdentity]) async {}
    func cancelEveryTask() async {}
}

/// Mobile data: with the switch off, the queue may send nothing.
private struct OnMobileData: NetworkPathProviding {
    func currentPath() -> NetworkPath {
        NetworkPath(usesCellular: true, isExpensive: true, isConstrained: false)
    }
    func onPathChange(_ handler: @escaping OutboxTrigger) {}
}

@MainActor
private struct FixRig {
    let repository: OutboxRepository
    let outbox: Outbox
    let uploads: UploadSettings
    let suite: String

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transfers-fix").appending(path: UUID().uuidString)
        let credentials = SignedIn()
        repository = try OutboxRepository(
            root: root, stillCurrent: { credentials.stillCurrent(epoch: $0) })
        suite = "transfers.fix.\(UUID().uuidString)"
        let preferences = UploadPreferences(defaults: UserDefaults(suiteName: suite)!)
        outbox = Outbox(
            repository: repository, credentials: credentials, http: RefusingHTTP(),
            scheduler: NoChunks(), completion: MemoCompletionEndpoint(http: RefusingHTTP()),
            network: OnMobileData(), preferences: preferences)
        uploads = UploadSettings(preferences: preferences)
    }

    func queued(_ one: UploadJob) async throws -> UUID {
        try await repository.save(one)
        await outbox.refresh()
        return one.id
    }

    func forget() { UserDefaults.standard.removePersistentDomain(forName: suite) }
}

@MainActor
@Suite("Transfers: each fix runs through the real outbox")
struct TransfersFixTests {
    @Test("Retry now clears the hold through the outbox's own retry")
    func retryNow() async throws {
        let rig = try FixRig()
        defer { rig.forget() }
        let id = try await rig.queued(job(.held, hold: .serverRefused, files: []))
        let done = await TransfersFixer().perform(
            .retryNow, jobID: id, outbox: rig.outbox, uploads: rig.uploads, signIn: {},
            reopen: { _ in })
        #expect(done)
        let after = await rig.repository.job(id)
        #expect(after?.state != .held)
        #expect(after?.holdReason == nil)
    }

    @Test("Remove throws the capture away through the outbox's own discard")
    func remove() async throws {
        let rig = try FixRig()
        defer { rig.forget() }
        let id = try await rig.queued(job(.held, hold: .tooLarge))
        await TransfersFixer().perform(
            .remove, jobID: id, outbox: rig.outbox, uploads: rig.uploads, signIn: {},
            reopen: { _ in })
        #expect(await rig.repository.job(id) == nil)
        #expect(rig.outbox.transfers.jobs.isEmpty)
    }

    @Test("Use mobile data turns on the upload preference the queue reads")
    func useMobileData() async throws {
        let rig = try FixRig()
        defer { rig.forget() }
        let id = try await rig.queued(job(.waiting, wait: .homeNetwork))
        #expect(rig.outbox.uploadVerdict == .refused(.cellularWhileMobileDataOff))
        await TransfersFixer().perform(
            .useMobileData, jobID: id, outbox: rig.outbox, uploads: rig.uploads, signIn: {},
            reopen: { _ in })
        #expect(rig.uploads.allowsMobileData)
        #expect(rig.outbox.uploadPreferences.allowsMobileData)
        #expect(rig.outbox.uploadVerdict == .permitted)
    }

    @Test("Use mobile data without the settings model writes the same preference")
    func useMobileDataWithoutModel() async throws {
        let rig = try FixRig()
        defer { rig.forget() }
        let id = try await rig.queued(job(.waiting, wait: .homeNetwork))
        await TransfersFixer().perform(
            .useMobileData, jobID: id, outbox: rig.outbox, uploads: nil, signIn: {},
            reopen: { _ in })
        #expect(rig.outbox.uploadPreferences.allowsMobileData)
        #expect(rig.outbox.uploadVerdict == .permitted)
    }

    @Test("Use mobile data for this one releases that capture and changes neither setting")
    func useMobileDataForThisOne() async throws {
        let rig = try FixRig()
        defer { rig.forget() }
        let video = OutboxFile(
            relativePath: "v.mov", filename: "v.mov", mime: "video/quicktime",
            byteSize: UploadNetworkPolicy.mobileVideoLimit + 1)
        let id = try await rig.queued(job(.waiting, wait: .videoOverMobileLimit, files: [video]))
        let other = try await rig.queued(
            job(.waiting, wait: .videoOverMobileLimit, files: [video]))
        let done = await TransfersFixer().perform(
            .useMobileDataForThisOne, jobID: id, outbox: rig.outbox, uploads: rig.uploads,
            signIn: {}, reopen: { _ in })
        #expect(done)
        let after = await rig.repository.job(id)
        #expect(after?.videoOverMobileAllowed == true)
        #expect(after?.waitReason != .videoOverMobileLimit)
        #expect(await rig.repository.job(other)?.videoOverMobileAllowed == nil)
        #expect(rig.uploads.allowsMobileData == false)
        #expect(rig.outbox.uploadPreferences.allowsMobileData == false)
        let written = UserDefaults.standard.persistentDomain(forName: rig.suite)
        #expect(written?[UploadPreferences.mobileVideoPolicyKey] == nil)
    }

    @Test("Sign in takes the sign-in route and leaves the capture as it was")
    func signIn() async throws {
        let rig = try FixRig()
        defer { rig.forget() }
        let held = job(.held, hold: .signInRequired)
        let id = try await rig.queued(held)
        var routed = 0
        await TransfersFixer().perform(
            .signIn, jobID: id, outbox: rig.outbox, uploads: rig.uploads,
            signIn: { routed += 1 }, reopen: { _ in })
        #expect(routed == 1)
        await TransfersFixer().perform(
            .switchAccount, jobID: id, outbox: rig.outbox, uploads: rig.uploads,
            signIn: { routed += 1 }, reopen: { _ in })
        #expect(routed == 2)
        #expect(await rig.repository.job(id)?.holdReason == .signInRequired)
    }

    @Test("a capture made under another account offers the switch, which signs out and keeps it")
    func switchAccountKeepsTheCapture() async throws {
        let rig = try FixRig()
        defer { rig.forget() }
        let mismatched = job(.held, hold: .accountMismatch)
        let id = try await rig.queued(mismatched)
        let offered = TransfersPresentation.sections(
            for: rig.outbox.transfers, now: Date(), lastProgressAt: [:], verdict: .permitted)
        #expect(offered.first?.rows.first?.action == .switchAccount)
        var routed = 0
        var reopened = 0
        await TransfersFixer().perform(
            .switchAccount, jobID: id, outbox: rig.outbox, uploads: rig.uploads,
            signIn: { routed += 1 }, reopen: { _ in reopened += 1 })
        #expect(routed == 1)
        #expect(reopened == 0)
        let after = await rig.repository.job(id)
        #expect(after?.state == .held)
        #expect(after?.holdReason == .accountMismatch)
        #expect(after?.cancelledAt == nil)
        #expect(rig.outbox.transfers.job(id) != nil)
    }

    @Test("Reopen takes the capture back through the outbox's own cancel and opens the draft")
    func reopen() async throws {
        let rig = try FixRig()
        defer { rig.forget() }
        let id = try await rig.queued(job(.held, hold: .editIncomplete))
        var opened: RestoredDraft?
        await TransfersFixer().perform(
            .reopen, jobID: id, outbox: rig.outbox, uploads: rig.uploads, signIn: {},
            reopen: { opened = $0 })
        #expect(opened?.jobID == id)
        #expect(await rig.repository.job(id)?.cancelledAt != nil)
    }

    @Test("a second fix for the same capture while the first is out is refused, not sent beside it")
    func overlappingFixIsRefused() async throws {
        let rig = try FixRig()
        defer { rig.forget() }
        let id = try await rig.queued(job(.held, hold: .tooLarge))
        let fixer = TransfersFixer()
        async let first = fixer.perform(
            .remove, jobID: id, outbox: rig.outbox, uploads: rig.uploads, signIn: {},
            reopen: { _ in })
        async let second = fixer.perform(
            .remove, jobID: id, outbox: rig.outbox, uploads: rig.uploads, signIn: {},
            reopen: { _ in })
        let answers = await [first, second]
        #expect(answers.filter { $0 }.count == 1)
        // Released once the first is done: the next tap is heard again.
        #expect(
            await fixer.perform(
                .signIn, jobID: id, outbox: rig.outbox, uploads: rig.uploads, signIn: {},
                reopen: { _ in }))
    }
}

/// Items Post left in Photos (MEMNG-952): the sheet lists them with the reason they are not here,
/// and the one that Photos access does not reach offers Settings.
@MainActor
@Suite("Transfers: items still in Photos")
struct TransfersInPhotosTests {
    @Test("denied access: the loaded file is listed as it goes, the rest say Allow Photos access")
    func deniedItemsSayAllowAccess() {
        var capture = job(.uploading, files: [file(100)])
        capture.staging = [
            StagingFile(assetIdentifier: "p1", needsPhotosAccess: true),
            StagingFile(assetIdentifier: "p2"),
        ]
        let sections = TransfersPresentation.sections(
            for: ledger([capture]), now: start, lastProgressAt: [:], verdict: .permitted)
        let rows = sections.first?.rows ?? []
        #expect(rows.count == 3)
        #expect(rows.first?.reason == nil, "the loaded file is moving and says nothing")
        #expect(rows.first?.action == nil)
        #expect(rows[1].reason == "Allow Photos access to send the rest")
        #expect(rows[1].action == .openSettings)
        #expect(rows[1].filename == TransferLedger.inPhotosName)
        #expect(rows[2].reason == TransfersPresentation.copyingFromPhotos)
        #expect(rows[2].action == nil)
        #expect(TransfersAction.openSettings.title == "Open Settings")
    }

    @Test("Open Settings opens Settings and touches the capture not at all")
    func openSettingsOpensSettings() async throws {
        let rig = try FixRig()
        defer { rig.forget() }
        var capture = job(.waiting)
        capture.staging = [StagingFile(assetIdentifier: "p1", needsPhotosAccess: true)]
        let id = try await rig.queued(capture)
        let before = await rig.repository.job(id)
        var opened = 0
        let done = await TransfersFixer().perform(
            .openSettings, jobID: id, outbox: rig.outbox, uploads: rig.uploads, signIn: {},
            reopen: { _ in }, openSettings: { opened += 1 })
        #expect(done)
        #expect(opened == 1)
        #expect(await rig.repository.job(id) == before)
    }
}
