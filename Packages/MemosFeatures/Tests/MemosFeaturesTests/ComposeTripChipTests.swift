import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import MemosOutbox
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// What every Post of a sheet sent, in order, and what the outbox answered when it was asked.
@MainActor
private final class PostLog {
    private(set) var sent: [ComposeSubmission] = []
    var enqueued: [Bool] = []
    private var answers: [ComposeOutcome]

    init(answers: [ComposeOutcome] = []) { self.answers = answers }

    func take(_ submission: ComposeSubmission) async -> ComposeOutcome {
        sent.append(submission)
        return answers.isEmpty ? .saved : answers.removeFirst()
    }
}

// MARK: - The stub transport the real outbox sends through

/// The network, and only the network: it records every request and answers as a healthy server.
private final class RecordingHTTP: OutboxHTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { seen } }

    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        lock.withLock { seen.append(request) }
        switch (request.httpMethod ?? "", request.url?.path() ?? "") {
        case ("GET", "/health"):
            return OutboxHTTPResponse(statusCode: 200)
        case ("POST", "/api/memos"):
            let body = try JSONSerialization.data(withJSONObject: ["uid": "m1"])
            return OutboxHTTPResponse(
                statusCode: 201, body: body, headers: ["Content-Type": "application/json"])
        default:
            return OutboxHTTPResponse(statusCode: 500)
        }
    }
}

private struct SignedIn: OutboxCredentialsProviding {
    /// Who the session answers as at the moment the outbox acquires its credentials.
    var owner = "alice"

    func currentCredentials() async -> OutboxCredentials? {
        OutboxCredentials(
            serverBaseURL: URL(string: "https://memos.example.invalid")!,
            ownerSubject: owner, token: "pat-token")
    }
    func isCurrent(_ credentials: OutboxCredentials) -> Bool { true }
    func stillCurrent(epoch: Int) -> Bool { true }
}

/// A capture with no pictures puts nothing on the background session; this one is never asked.
private struct NoChunks: OutboxChunkScheduling {
    func inFlight() async -> [OutboxTaskIdentity] { [] }
    func upload(
        _ request: URLRequest, fromFile file: URL, identity: OutboxTaskIdentity,
        under authority: SendAuthority, issuedUnder epoch: Int
    ) async {}
    func cancel(_ identities: [OutboxTaskIdentity]) async {}
    func cancelEveryTask() async {}
}

private struct OnWiFi: NetworkPathProviding {
    func currentPath() -> NetworkPath {
        NetworkPath(usesCellular: false, isExpensive: false, isConstrained: false)
    }
    func onPathChange(_ handler: @escaping OutboxTrigger) {}
}

/// The account default as Post reads it, under `owner` on the stub server.
private func composed(_ visibility: MemoVisibility?, under owner: String = "alice")
    -> ComposedAccountDefault
{
    ComposedAccountDefault(
        visibility: visibility,
        account: AccountBinding(
            serverBaseURL: URL(string: "https://memos.example.invalid")!, ownerSubject: owner))
}

/// The real outbox, signed in and on Wi-Fi, sending through `http` from a queue under `root`.
@MainActor
private func signedInOutbox(
    over http: RecordingHTTP, at root: URL, as owner: String = "alice"
) throws -> Outbox {
    let credentials = SignedIn(owner: owner)
    let repository = try OutboxRepository(
        root: root.appending(path: "outbox"),
        stillCurrent: { credentials.stillCurrent(epoch: $0) })
    return Outbox(
        repository: repository,
        credentials: credentials,
        http: http,
        scheduler: NoChunks(),
        completion: MemoCompletionEndpoint(http: http),
        network: OnWiFi(),
        preferences: UploadPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    )
}

@MainActor
@Suite("Composer trip chip")
struct ComposeTripChipTests {
    private let trip = ComposePinnedTrip(title: "Portugal 2026", tag: "portugal2026")
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "compose-trip-chip").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")

    private func draft(_ content: String) -> ComposeView.Mode {
        .create(
            restoring: ComposeRestore(
                jobID: UUID(), content: content, visibility: .private,
                capturedAt: Date(timeIntervalSince1970: 1_750_000_000), pictures: []))
    }

    private let edit = ComposeView.Mode.edit(
        uid: "m1", content: "x", createdAt: Date(timeIntervalSince1970: 0), attachments: [])

    /// The chip speaks of the trip, never of a pin (MEMNG-781).
    private func chipShown(_ labels: [String]) -> Bool {
        labels.contains("Trip, Portugal 2026")
    }

    /// The sheet as a new capture of `content` opens it, offered `pinnedTrip`.
    private func sheet(
        _ content: String,
        pinnedTrip: ComposePinnedTrip?,
        submit: @escaping (ComposeSubmission) async -> ComposeOutcome = { _ in .saved }
    ) -> ComposeView {
        ComposeView(mode: draft(content), pinnedTrip: pinnedTrip, submit: submit)
    }

    // MARK: - The chip's state

    @Test("a new memo gets the chip; an edit never does")
    func createOnly() {
        #expect(ComposeTripChip(mode: .create(restoring: nil), offered: trip).shown == trip)
        #expect(ComposeTripChip(mode: draft("x"), offered: trip).shown == trip)
        #expect(ComposeTripChip(mode: edit, offered: trip).shown == nil)
        #expect(ComposeTripChip(mode: edit, offered: trip).submittedContent("x") == "x")
        #expect(ComposeTripChip(mode: .create(restoring: nil), offered: nil).shown == nil)
    }

    @Test("the x takes the chip and the tag off this sheet only")
    func dismissIsPerSheet() {
        var chip = ComposeTripChip(mode: .create(restoring: nil), offered: trip)
        #expect(chip.submittedContent("Lisbon") == "Lisbon\n#portugal2026")
        chip.dismiss()
        #expect(chip.shown == nil)
        #expect(chip.submittedContent("Lisbon") == "Lisbon")
        let next = ComposeTripChip(mode: .create(restoring: nil), offered: trip)
        #expect(next.shown == trip, "a new sheet with the same pin lost its chip")
    }

    @Test("a restored capture that already carries the tag is not tagged twice")
    func restoredDraftIsNotTaggedTwice() {
        let restored = "Lisbon\n#portugal2026"
        let chip = ComposeTripChip(mode: draft(restored), offered: trip)
        #expect(chip.submittedContent(restored) == restored)
        #expect(
            chip.submittedContent("the word portugal2026")
                == "the word portugal2026\n#portugal2026")
    }

    // MARK: - The screen

    @Test("the chip shows the pinned trip's title on a new memo, and nowhere else")
    func chipRenders() {
        #expect(chipShown(ScreenProbe.labels(of: sheet("x", pinnedTrip: trip))))
        #expect(!chipShown(ScreenProbe.labels(of: sheet("x", pinnedTrip: nil))))
        let editing = ComposeView(mode: edit, pinnedTrip: trip) { _ in .saved }
        #expect(!chipShown(ScreenProbe.labels(of: editing)), "an edit showed the chip")
    }

    @Test("Post sends the tag line; after the x it does not; a new sheet has the chip back")
    func postCarriesTheTag() async {
        let log = PostLog()
        let (posted, removed, postedAgain, waits) = await PressProbe.withScreen(
            sheet("Lisbon at dusk", pinnedTrip: trip) { await log.take($0) },
            height: 852
        ) { screen in
            let posted = screen.press("Post")
            // The send lands inside the submission, which ends only after it: the next press
            // waits for Post to be live again, not only for the log.
            let sentOnce = await screen.until { log.sent.count == 1 && screen.isLive("Post") }
            let removed = screen.press("Remove trip tag")
            let chipGone = await screen.until { !screen.says("Trip, Portugal 2026") }
            let postedAgain = screen.press("Post")
            let sentTwice = await screen.until { log.sent.count == 2 }
            return (posted, removed, postedAgain, (sentOnce, chipGone, sentTwice))
        }
        #expect(waits.0, "the first Post was not recorded within 5 s")
        #expect(waits.1, "the chip was still shown 5 s after its x was pressed")
        #expect(waits.2, "the second Post was not recorded within 5 s")
        #expect(posted && removed && postedAgain)
        #expect(log.sent.map(\.content) == ["Lisbon at dusk\n#portugal2026", "Lisbon at dusk"])

        let again = ScreenProbe.labels(of: sheet("Lisbon at dusk", pinnedTrip: trip))
        #expect(chipShown(again), "a new sheet with the same pin did not show the chip")
    }

    @Test("a failed post tried again sends the tag line once, from the unchanged words")
    func retryDoesNotDoubleTheLine() async {
        let log = PostLog(answers: [.failed(.transport(sent: false)), .saved])
        let ((wordsShown, lineShown), waits) = await PressProbe.withScreen(
            sheet("Lisbon at dusk", pinnedTrip: trip) { await log.take($0) },
            height: 852
        ) { screen in
            _ = screen.press("Post")
            let sentOnce = await screen.until { log.sent.count == 1 && screen.isLive("Post") }
            await screen.settle()
            // What the editor shows after the failure: the words as typed, and no tag line.
            let shown = (screen.says("Lisbon at dusk"), screen.says("#portugal2026"))
            _ = screen.press("Post")
            let sentTwice = await screen.until { log.sent.count == 2 }
            return (shown, (sentOnce, sentTwice))
        }
        #expect(waits.0, "the failed Post was not recorded within 5 s")
        #expect(waits.1, "the Post tried again was not recorded within 5 s")
        #expect(wordsShown, "the editor's words could not be read: the next check proves nothing")
        #expect(!lineShown, "the tag line was written into the editor")
        let once = "Lisbon at dusk\n#portugal2026"
        #expect(log.sent.map(\.content) == [once, once])
    }

    @Test("a restored capture already carrying the tag is posted as it stands")
    func restoredPostIsNotDoubled() async {
        let log = PostLog()
        let sent = await PressProbe.withScreen(
            sheet("Lisbon\n#portugal2026", pinnedTrip: trip) { await log.take($0) },
            height: 852
        ) { screen in
            _ = screen.press("Post")
            return await screen.until { log.sent.count == 1 }
        }
        #expect(sent, "the Post was not recorded within 5 s")
        #expect(log.sent.map(\.content) == ["Lisbon\n#portugal2026"])
    }

    // MARK: - The wire

    @Test("the sheet's Post, through the timeline's enqueue and the real outbox, reaches the wire")
    func wireBodyCarriesTheTag() async throws {
        let http = RecordingHTTP()
        let outbox = try signedInOutbox(over: http, at: root)
        let log = PostLog()
        await PressProbe.withScreen(
            sheet("Lisbon at dusk", pinnedTrip: trip) { submission in
                _ = await log.take(submission)
                let ok = await TimelineView.enqueue(submission, into: outbox, accountDefault: nil)
                log.enqueued.append(ok)
                return ok ? .saved : .failed(.storage)
            },
            height: 852
        ) { screen in
            _ = screen.press("Post")
            await screen.settle(turns: 200, until: { !log.enqueued.isEmpty })
        }
        #expect(log.enqueued == [true], "the outbox did not take the capture")
        for _ in 0..<500 where http.requests.allSatisfy({ $0.httpMethod != "POST" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let create = try #require(
            http.requests.first { $0.httpMethod == "POST" && $0.url?.path() == "/api/memos" })
        let body = try #require(create.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let content = try #require(json["content"] as? String)
        #expect(content == "Lisbon at dusk\n#portugal2026")
        #expect(content.hasSuffix("\n#portugal2026"))
    }
}

// MARK: - Who sees a memo written while a trip is pinned

/// The server an EDIT talks to: one PUBLIC memo to load, and every PATCH body kept as it was sent.
nonisolated private final class PublicMemoServer: ClientTransport, @unchecked Sendable {
    static let list = "list_memos_api_memos_get"
    static let patch = "patch_memo_api_memos__uid__patch"
    static let memo = """
        {"uid":"m1","owner":"fabian","mine":true,"content":"Lisbon at dusk",\
        "visibility":"PUBLIC","pinned":false,"created_at":"2026-08-23T09:00:00Z",\
        "updated_at":"2026-08-23T09:00:00.443000Z","archived_at":null,"tags":[],\
        "attachments":[]}
        """

    private let lock = NSLock()
    private var bodies: [Data] = []

    var patches: [Data] { lock.withLock { bodies } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        switch operationID {
        case Self.list:
            let page = #"{"items":[\#(Self.memo)],"nextCursor":null,"totalCount":null}"#
            return (response, HTTPBody(page))
        case Self.patch:
            let sent = try await Data(collecting: body ?? HTTPBody(), upTo: 1 << 20)
            lock.withLock { bodies.append(sent) }
            return (response, HTTPBody(Self.memo))
        default:
            return (HTTPResponse(status: .internalServerError), nil)
        }
    }
}

/// A trip post is for the two of us, so while a trip is pinned a NEW memo starts on "Just us" —
/// and only starts there: the pill stays the person's, and the ✕ takes back only what the pin
/// chose. Asserted where it matters, in the body the real outbox puts on the wire.
@MainActor
@Suite("Composer trip visibility")
struct ComposeTripVisibilityTests {
    private let trip = ComposePinnedTrip(title: "Portugal 2026", tag: "portugal2026")
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "compose-trip-visibility").appending(path: UUID().uuidString)

    /// A NEW memo's sheet whose Post goes the timeline's way — `TimelineView.post`, with an
    /// account default the app knows, into the real outbox.
    private func newMemo(
        pinnedTrip: ComposePinnedTrip?, into outbox: Outbox, log: PostLog
    ) -> ComposeView {
        ComposeView(mode: .create(restoring: nil), pinnedTrip: pinnedTrip) { submission in
            _ = await log.take(submission)
            let outcome = await TimelineView.post(
                submission, restoring: nil, accountDefault: composed(.public),
                resubmit: { _, _ in .accepted },
                enqueue: { await TimelineView.enqueue($0, into: outbox, accountDefault: $1) })
            log.enqueued.append(outcome == .saved)
            return outcome == .saved ? .saved : .failed(.storage)
        }
    }

    /// Types into the sheet's editor through the text view's own input path, the one the keyboard
    /// uses, so the editor's binding hears it. False when there was no editor to type into.
    private func write(_ words: String, on screen: PressProbe.Screen) -> Bool {
        _ = screen.element(labelled: "Post")
        guard let editor = Self.textView(in: screen.window) else { return false }
        editor.insertText(words)
        return true
    }

    private static func textView(in view: UIView) -> UITextView? {
        if let found = view as? UITextView { return found }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    /// The create's JSON body, once the outbox has sent it.
    private func createBody(_ http: RecordingHTTP) async throws -> [String: Any] {
        for _ in 0..<500 where http.requests.allSatisfy({ $0.httpMethod != "POST" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let create = try #require(
            http.requests.first { $0.httpMethod == "POST" && $0.url?.path() == "/api/memos" })
        let body = try #require(create.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// Opens a new memo, types, optionally presses the chip's ✕, and posts. Says what the pill
    /// read before Post, and whether every step found what it pressed.
    private func post(
        pinnedTrip: ComposePinnedTrip?, removingTheTrip: Bool = false, into outbox: Outbox,
        log: PostLog
    ) async -> (pill: String?, pressed: Bool) {
        await PressProbe.withScreen(
            newMemo(pinnedTrip: pinnedTrip, into: outbox, log: log), height: 852
        ) { screen in
            let typed = write("Lisbon at dusk", on: screen)
            await screen.settle()
            var removed = true
            if removingTheTrip {
                removed = screen.press("Remove trip tag")
                await screen.settle(until: { !screen.says("Trip, Portugal 2026") })
            }
            let pill = MemoVisibility.allCases.map { "Visibility: \($0.label)" }
                .first { screen.says($0) && !screen.says("\($0), the account default") }
            let posted = screen.press("Post")
            await screen.settle(turns: 200, until: { !log.enqueued.isEmpty })
            return (pill, typed && removed && posted)
        }
    }

    @Test("with a trip pinned and the pill untouched, the new memo goes out as Just us")
    func pinnedPostIsProtected() async throws {
        let http = RecordingHTTP()
        let log = PostLog()
        let queue = try signedInOutbox(over: http, at: root)
        let (pill, pressed) = await post(pinnedTrip: trip, into: queue, log: log)
        #expect(pressed, "the sheet could not be typed into or posted: nothing below proves much")
        #expect(log.enqueued == [true], "the outbox did not take the capture")
        #expect(pill == "Visibility: \(MemoVisibility.protected.label)", "the pill did not say so")
        let body = try await createBody(http)
        #expect(body["content"] as? String == "Lisbon at dusk\n#portugal2026")
        #expect(body["visibility"] as? String == "PROTECTED")
    }

    @Test("with no trip pinned, the new memo states the account default it was composed under")
    func unpinnedPostIsTheAccountDefault() async throws {
        let http = RecordingHTTP()
        let log = PostLog()
        let queue = try signedInOutbox(over: http, at: root)
        let (pill, pressed) = await post(pinnedTrip: nil, into: queue, log: log)
        #expect(pressed, "the sheet could not be typed into or posted: nothing below proves much")
        #expect(log.enqueued == [true], "the outbox did not take the capture")
        #expect(pill == nil, "a pill with no pin said something other than the account default")
        #expect(log.sent.map(\.visibility) == [nil])
        let body = try await createBody(http)
        #expect(body["content"] as? String == "Lisbon at dusk", "positive control: body was read")
        #expect(
            body["visibility"] as? String == "PUBLIC",
            "Default went out unresolved: the server would apply its default at upload time")
    }

    @Test("the x before Post puts an untouched pill back on the account default")
    func removedTripPostIsTheAccountDefault() async throws {
        let http = RecordingHTTP()
        let log = PostLog()
        let queue = try signedInOutbox(over: http, at: root)
        let (pill, pressed) = await post(
            pinnedTrip: trip, removingTheTrip: true, into: queue, log: log)
        #expect(pressed, "the sheet could not be typed into or posted: nothing below proves much")
        #expect(log.enqueued == [true], "the outbox did not take the capture")
        #expect(pill == nil, "the pill kept the pin's choice after the trip was taken off")
        #expect(log.sent.map(\.visibility) == [nil])
        let body = try await createBody(http)
        #expect(body["content"] as? String == "Lisbon at dusk", "positive control: body was read")
        #expect(
            body["visibility"] as? String == "PUBLIC",
            "Default went out unresolved: the server would apply its default at upload time")
    }

    @Test("a pill set to Public by hand stays Public with the trip pinned, the x or not")
    func handChosenPublicStaysPublic() async throws {
        // What the pill writes is `chosen`: the sheet binds the menu to exactly that property.
        var pick = ComposeVisibilityPick(mode: .create(restoring: nil), offered: trip)
        pick.chosen = .public
        var chip = ComposeTripChip(mode: .create(restoring: nil), offered: trip)
        let kept = ComposeSubmission(
            content: chip.submittedContent("Lisbon at dusk"), visibility: pick.selection)
        chip.dismiss()
        pick.tripRemoved()
        let removed = ComposeSubmission(
            content: chip.submittedContent("Lisbon at dusk"), visibility: pick.selection)

        for (submission, content) in [
            (kept, "Lisbon at dusk\n#portugal2026"), (removed, "Lisbon at dusk"),
        ] {
            let http = RecordingHTTP()
            let queue = try signedInOutbox(
                over: http, at: root.appending(path: UUID().uuidString))
            let outcome = await TimelineView.post(
                submission, restoring: nil, accountDefault: composed(.private),
                resubmit: { _, _ in .accepted },
                enqueue: { await TimelineView.enqueue($0, into: queue, accountDefault: $1) })
            #expect(outcome == .saved)
            let body = try await createBody(http)
            #expect(body["content"] as? String == content, "positive control: body was read")
            #expect(body["visibility"] as? String == "PUBLIC")
        }
    }

    // MARK: - Default is resolved when the memo is composed (MEMNG-776)

    /// A fresh capture through `TimelineView.post` with nothing on the pill, into the real outbox.
    private func postFresh(
        _ visibility: MemoVisibility?, accountDefault: ComposedAccountDefault?
    ) async throws -> (outcome: MemosFeatures.TimelineView.PostOutcome, body: [String: Any]) {
        let http = RecordingHTTP()
        let queue = try signedInOutbox(over: http, at: root.appending(path: UUID().uuidString))
        let outcome = await TimelineView.post(
            ComposeSubmission(content: "Lisbon at dusk", visibility: visibility),
            restoring: nil, accountDefault: accountDefault,
            resubmit: { _, _ in .accepted },
            enqueue: { await TimelineView.enqueue($0, into: queue, accountDefault: $1) })
        return (outcome, try await createBody(http))
    }

    /// Composed while the account default is Private: the job states PRIVATE, so a default
    /// changed to Public before the queue drains cannot reach this memo.
    @Test("a fresh capture on Default carries the account default it was composed under")
    func freshDefaultCarriesTheComposedDefault() async throws {
        let (outcome, body) = try await postFresh(nil, accountDefault: composed(.private))
        #expect(outcome == .saved)
        #expect(body["content"] as? String == "Lisbon at dusk", "positive control: body was read")
        #expect(body["visibility"] as? String == "PRIVATE")
    }

    /// No account default known yet: the capture still goes, stating nothing, rather than being
    /// refused — a capture staged before the account had an answer is not lost for it.
    @Test("a fresh capture on Default with no known account default states nothing and is kept")
    func freshDefaultWithUnknownAccountDefaultStatesNothing() async throws {
        let (outcome, body) = try await postFresh(nil, accountDefault: composed(nil))
        #expect(outcome == .saved, "the capture was refused instead of queued")
        #expect(body["content"] as? String == "Lisbon at dusk", "positive control: body was read")
        #expect(body["visibility"] == nil)
    }

    @Test("a fresh capture's own pick wins over the account default")
    func freshPickWinsOverTheAccountDefault() async throws {
        let (outcome, body) = try await postFresh(.public, accountDefault: composed(.private))
        #expect(outcome == .saved)
        #expect(body["content"] as? String == "Lisbon at dusk", "positive control: body was read")
        #expect(body["visibility"] as? String == "PUBLIC")
    }

    /// The default was read while alice was signed in; by the time the outbox acquires its
    /// credentials the session answers as bob. Alice's PRIVATE must not be stamped on a capture
    /// bound to bob, so the capture is refused before anything reaches the disk or the wire.
    @Test("a capture composed under one account is refused when another would send it")
    func aCaptureComposedUnderAnotherAccountIsRefused() async throws {
        let http = RecordingHTTP()
        let queue = try signedInOutbox(
            over: http, at: root.appending(path: UUID().uuidString), as: "bob")
        let outcome = await TimelineView.post(
            ComposeSubmission(content: "Lisbon at dusk", visibility: nil),
            restoring: nil, accountDefault: composed(.private, under: "alice"),
            resubmit: { _, _ in .accepted },
            enqueue: { await TimelineView.enqueue($0, into: queue, accountDefault: $1) })
        #expect(outcome == .enqueueFailed)
        #expect(queue.lastEnqueueFailure == .notSignedIn)
        await queue.refresh()
        #expect(queue.jobs.isEmpty, "a job was written for the other account")
        #expect(http.requests.isEmpty, "something reached the wire")

        // Positive control: the same outbox takes a capture composed under its own account.
        let mine = await TimelineView.post(
            ComposeSubmission(content: "Lisbon at dusk", visibility: nil),
            restoring: nil, accountDefault: composed(.private, under: "bob"),
            resubmit: { _, _ in .accepted },
            enqueue: { await TimelineView.enqueue($0, into: queue, accountDefault: $1) })
        #expect(mine == .saved)
        let body = try await createBody(http)
        #expect(body["visibility"] as? String == "PRIVATE")
    }

    // MARK: - Who chose it

    @Test("a pinned trip suggests Just us to a fresh capture, and to nothing else")
    func onlyAFreshCaptureIsPreselected() {
        let fresh = ComposeView.Mode.create(restoring: nil)
        let edit = ComposeView.Mode.edit(
            uid: "m1", content: "x", createdAt: Date(timeIntervalSince1970: 0), attachments: [])
        func restored(_ visibility: MemoVisibility?) -> ComposeView.Mode {
            .create(
                restoring: ComposeRestore(
                    jobID: UUID(), content: "x", visibility: visibility,
                    capturedAt: Date(timeIntervalSince1970: 0), pictures: []))
        }

        let pinned = ComposeVisibilityPick(mode: fresh, offered: trip)
        #expect(pinned.selection == .protected)
        #expect(pinned.isSuggested)
        #expect(ComposeVisibilityPick(mode: fresh, offered: nil).selection == nil)
        #expect(ComposeVisibilityPick(mode: edit, offered: trip).selection == nil)
        #expect(ComposeVisibilityPick(mode: restored(nil), offered: trip).selection == nil)
        let stopped = ComposeVisibilityPick(mode: restored(.private), offered: trip)
        #expect(stopped.selection == .private)
        #expect(!stopped.isSuggested)
    }

    @Test("the x takes back the pin's suggestion and never the person's choice")
    func removalTakesBackOnlyTheSuggestion() {
        let fresh = ComposeView.Mode.create(restoring: nil)

        var untouched = ComposeVisibilityPick(mode: fresh, offered: trip)
        untouched.tripRemoved()
        #expect(untouched.selection == nil, "an untouched suggestion outlived the trip")

        // Every choice the menu offers, the suggestion's own value and Default included.
        let choices: [MemoVisibility?] = [nil, .private, .protected, .public]
        for choice in choices {
            var pick = ComposeVisibilityPick(mode: fresh, offered: trip)
            pick.chosen = choice
            #expect(!pick.isSuggested)
            pick.tripRemoved()
            #expect(pick.selection == choice, "the x overrode a pill set by hand")
        }

        var unpinned = ComposeVisibilityPick(mode: fresh, offered: nil)
        unpinned.chosen = .private
        unpinned.tripRemoved()
        #expect(unpinned.selection == .private)
    }

    @Test("editing a PUBLIC memo while a trip is pinned leaves it PUBLIC")
    func editKeepsItsVisibility() async throws {
        let server = PublicMemoServer()
        let base = URL(string: "https://memos.example.invalid")!
        let handle = SessionHandle(
            client: APIClientFactory.make(
                configuration: ServerConfiguration(baseURL: base),
                token: { "memos_pat_trip" }, transport: server),
            generation: 1)
        let timeline = TimelineStore()
        await timeline.refresh(using: handle, baseURL: base)
        #expect(timeline.memos.first?.visibility == .public, "positive control: the memo loaded")

        let log = PostLog()
        let edit = ComposeView(
            mode: .edit(
                uid: "m1", content: "Lisbon at dusk", createdAt: Date(timeIntervalSince1970: 0),
                attachments: []),
            pinnedTrip: trip
        ) { submission in
            _ = await log.take(submission)
            // The timeline's edit lane, as `TimelineView.submit` calls it.
            return await timeline.edit(
                uid: "m1", content: submission.content, attaching: [],
                listing: submission.pictures, using: handle, baseURL: base)
        }
        let saved = await PressProbe.withScreen(edit, height: 852) { screen in
            let saved = screen.press("Save")
            await screen.settle(turns: 200, until: { !server.patches.isEmpty })
            return saved
        }
        #expect(saved)
        #expect(log.sent.map(\.visibility) == [nil], "the edit sheet stated a visibility")
        let sent = try #require(server.patches.first)
        let body = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["content"] as? String == "Lisbon at dusk", "positive control: body was read")
        #expect(body["visibility"] == nil, "an edit sent a visibility")
        #expect(timeline.memos.first?.visibility == .public)
    }
}

// MARK: - Today's trip (MEMNG-781, decision 3)

/// 8 October 2026 at a given hour and minute in `zone`.
private func at(
    _ day: Int, _ hour: Int = 12, _ minute: Int = 0, month: Int = 10,
    in zone: String = "Europe/Lisbon"
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar.date(
        from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private func trip(
    _ uid: String, tag: String?, from start: Date?, to end: Date?,
    zone: String? = "Europe/Lisbon"
) -> Trip {
    Trip(
        uid: uid, title: "Trip \(uid)", tag: tag, spanStart: start, spanEnd: end, tz: zone,
        createdAt: at(1), updatedAt: at(1))
}

/// Which trip a new memo is offered: the one whose span holds today, in the span's own zone.
@MainActor
@Suite("Composer trip chip: today's trip")
struct ComposeTodaysTripTests {
    /// 8 October 2026, 13:00 in Lisbon.
    private let now = at(8, 13)

    private func offered(_ trips: [Trip], at instant: Date? = nil) -> String? {
        ComposePinnedTrip.offered(among: trips, now: instant ?? now)?.tag
    }

    @Test("a span holding today offers its trip; one that ended before today does not")
    func insideAndOutside() {
        #expect(offered([trip("a", tag: "lisbon", from: at(5, 0), to: at(12, 23))]) == "lisbon")
        #expect(offered([trip("b", tag: "porto", from: at(1, 0), to: at(5, 23))]) == nil)
        #expect(offered([trip("c", tag: "faro", from: at(9, 0), to: at(12, 23))]) == nil)
    }

    @Test("the first and the last day count whole, whatever the hour the span starts or ends")
    func boundaryDays() {
        // Ended at 09:00 today, four hours ago: today is still its last day.
        #expect(offered([trip("a", tag: "endday", from: at(5, 0), to: at(8, 9))]) == "endday")
        // Starts at 20:00 today, seven hours from now: today is already its first day.
        #expect(offered([trip("b", tag: "startday", from: at(8, 20), to: at(12))]) == "startday")
    }

    @Test("today is the span's zone's today, not the device's or UTC's")
    func todayInTheSpansZone() {
        // Ended 23:30 on the 7th in Lisbon; it is 00:15 on the 8th there, still the 7th in UTC.
        let span = trip("a", tag: "late", from: at(1, 0), to: at(7, 23, 30))
        #expect(offered([span], at: at(8, 0, 15)) == nil, "the span's last day was yesterday")
        #expect(offered([span], at: at(7, 23, 45)) == "late", "control: its last day")
        // The same instants in New York's zone: still the 7th there, so still its last day.
        let west = trip(
            "b", tag: "west", from: at(1, 0, in: "America/New_York"),
            to: at(7, 18, 30, in: "America/New_York"), zone: "America/New_York")
        #expect(offered([west], at: at(8, 0, 15)) == "west")
    }

    @Test("a span with no end in sight yet holds today when it has begun")
    func endInTheFuture() {
        let long = trip("a", tag: "sabbatical", from: at(1, 0), to: at(31, 23, month: 12))
        #expect(offered([long]) == "sabbatical")
    }

    @Test("a trip with no span, or with no tag, is never offered")
    func noSpanOrNoTag() {
        #expect(offered([trip("a", tag: "nospan", from: nil, to: nil)]) == nil)
        #expect(offered([trip("b", tag: nil, from: at(5, 0), to: at(12))]) == nil)
        #expect(offered([trip("c", tag: "", from: at(5, 0), to: at(12))]) == nil)
        #expect(ComposePinnedTrip.offered(from: nil, now: now) == nil)
    }

    @Test("of two tagged trips holding today, the one begun later; equal starts, the shorter")
    func overlappingTaggedTrips() {
        let early = trip("a", tag: "portugal", from: at(1, 0), to: at(20))
        let late = trip("b", tag: "lisbon", from: at(6, 0), to: at(10))
        #expect(offered([early, late]) == "lisbon")
        #expect(offered([late, early]) == "lisbon", "the list's order decided")
        let wide = trip("c", tag: "wide", from: at(6, 0), to: at(20))
        #expect(offered([wide, late]) == "lisbon", "equal starts: the earlier end")
        let twin = trip("0", tag: "twin", from: at(6, 0), to: at(10))
        #expect(offered([late, twin]) == "twin", "all equal: the smaller uid")
    }

    @Test("a span-only trip overlapping a tagged one leaves the tagged one offered")
    func spanOnlyNeverWins() {
        let tagged = trip("a", tag: "lisbon", from: at(1, 0), to: at(20))
        let spanOnly = trip("b", tag: nil, from: at(7, 0), to: at(9))
        #expect(offered([spanOnly, tagged]) == "lisbon")
    }

    @Test("the offer is the trip's title and tag")
    func offerIsTitleAndTag() {
        let found = ComposePinnedTrip.offered(
            among: [trip("a", tag: "lisbon", from: at(5, 0), to: at(12))], now: now)
        #expect(found == ComposePinnedTrip(title: "Trip a", tag: "lisbon"))
    }
}

/// Whose identity a hosted reader of the trips follows; a test moves it.
@MainActor
@Observable
private final class IdentityBox {
    var identity: TimelineSnapshotIdentity?
    init(_ identity: TimelineSnapshotIdentity?) { self.identity = identity }
}

/// The session's trips read as the app reads them at a cold launch (`readsTrips`), with nothing
/// else on screen.
private struct TripsReader: View {
    let box: IdentityBox
    let trips: TripStore
    let access: (TimelineSnapshotIdentity?) -> CollectionsAccess?

    var body: some View {
        Color.clear.readsTrips(trips, under: box.identity) { access(box.identity) }
    }
}

/// The cold launch: the trip list is read at once, before any Collections screen appears, so a
/// capture opened from the Timeline is offered today's trip once that list has answered.
@MainActor
@Suite("Composer trip chip: the cold launch")
struct ComposeColdLaunchTripTests {
    private let alice = TimelineSnapshotIdentity(
        server: CollectionsWire.baseURL, subject: "fabian")
    private let bob = TimelineSnapshotIdentity(server: CollectionsWire.baseURL, subject: "bob")

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// A trip on `wire` whose span holds the real today, as the Timeline's sheet reads the clock.
    private static func seedToday(_ title: String, tag: String, on wire: CollectionsWire) {
        let now = Date()
        wire.transport.trips.seed(
            title, tag: tag, spanStart: stamp(now.addingTimeInterval(-86_400)),
            spanEnd: stamp(now.addingTimeInterval(86_400)), tz: "UTC")
    }

    private func sheetLabels(_ trips: TripStore) -> [String] {
        ScreenProbe.labels(
            of: TimelineView.editSheet(
                mode: .create(restoring: nil), isAsking: false, failure: nil,
                pinnedTrip: ComposePinnedTrip.offered(from: trips, now: Date()),
                send: { _ in }, submit: { _ in .saved }))
    }

    @Test("an unanswered list offers no chip; once it answers, a newly opened sheet has it")
    func coldLaunchOffersOnceTheListAnswers() async {
        let wire = CollectionsWire()
        Self.seedToday("Portugal 2026", tag: "portugal2026", on: wire)
        wire.transport.trips.hold(TripRows.list)
        let trips = TripStore(identity: alice, root: nil)
        let access = wire.access
        let view = TripsReader(box: IdentityBox(alice), trips: trips) { _ in access }
        await CollectionsHost.with(view) { screen in
            let asked = await screen.until { !wire.transport.trips.calls(TripRows.list).isEmpty }
            #expect(asked, "no trip list was asked for at launch")
            #expect(!sheetLabels(trips).contains("Trip, Portugal 2026"), "a chip before the answer")
            wire.transport.trips.release(TripRows.list)
            let answered = await screen.until { !trips.trips.isEmpty }
            #expect(answered, "the list never answered")
            #expect(sheetLabels(trips).contains("Trip, Portugal 2026"), "the new sheet has no chip")
        }
    }

    @Test("a list asked for one identity and answered after another's drops on arrival")
    func identityChangeDropsTheOldList() async {
        let wireA = CollectionsWire()
        Self.seedToday("Portugal 2026", tag: "portugal2026", on: wireA)
        wireA.transport.trips.hold(TripRows.list)
        let wireB = CollectionsWire()
        Self.seedToday("Bob's trip", tag: "bobs", on: wireB)
        let trips = TripStore(identity: alice, root: nil)
        let box = IdentityBox(alice)
        let (accessA, accessB) = (wireA.access, wireB.access)
        let view = TripsReader(box: box, trips: trips) { $0?.subject == "bob" ? accessB : accessA }
        await CollectionsHost.with(view) { screen in
            let asked = await screen.until { !wireA.transport.trips.calls(TripRows.list).isEmpty }
            #expect(asked, "no trip list was asked for at launch")
            box.identity = bob
            let moved = await screen.until { trips.trips.map(\.title) == ["Bob's trip"] }
            #expect(moved, "the new identity's list was not read: \(trips.trips.map(\.title))")
            wireA.transport.trips.release(TripRows.list)
            // Long enough for the held answer to land; it must change nothing when it does.
            _ = await screen.until(seconds: 1) { trips.trips.count != 1 }
            #expect(trips.trips.map(\.title) == ["Bob's trip"], "the old identity's list came back")
            #expect(trips.identity == bob)
        }
    }
}
