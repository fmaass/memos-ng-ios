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
    func currentCredentials() async -> OutboxCredentials? {
        OutboxCredentials(
            serverBaseURL: URL(string: "https://memos.example.invalid")!,
            ownerSubject: "alice", token: "pat-token")
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

/// The real outbox, signed in and on Wi-Fi, sending through `http` from a queue under `root`.
@MainActor
private func signedInOutbox(over http: RecordingHTTP, at root: URL) throws -> Outbox {
    let credentials = SignedIn()
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

    private func chipShown(_ labels: [String]) -> Bool {
        labels.contains("Pinned trip, Portugal 2026")
    }

    /// The sheet as a new capture of `content` opens it, offered `pinnedTrip`.
    private func sheet(
        _ content: String,
        pinnedTrip: ComposePinnedTrip?,
        submit: @escaping (ComposeSubmission) async -> ComposeOutcome = { _ in .saved }
    ) -> ComposeView {
        ComposeView(mode: draft(content), pinnedTrip: pinnedTrip, submit: submit)
    }

    // MARK: - The offer, read from the store

    @Test("the offer is the pinned trip's title and first tag, while the pin lasts")
    func offerFollowsThePin() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let store = CollectionStore(identity: alice, root: root, now: { now })
        let made = store.create(title: "Portugal 2026", tags: ["portugal2026", "lisbon"])
        #expect(ComposePinnedTrip.offered(by: store, now: now) == nil, "an unpinned trip offered")

        store.pin(id: made.id, now: now)
        let until = try #require(store.records.first?.pinnedUntil)
        #expect(ComposePinnedTrip.offered(by: store, now: now) == trip)
        #expect(
            ComposePinnedTrip.offered(by: store, now: until.addingTimeInterval(-1)) == trip)
        #expect(
            ComposePinnedTrip.offered(by: store, now: until) == nil,
            "a pin that ends exactly now is over and must not be offered")
        #expect(ComposePinnedTrip.offered(by: nil, now: now) == nil)
    }

    @Test("a pinned record with no tag offers nothing")
    func untaggedRecordOffersNothing() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let store = CollectionStore(identity: alice, root: root, now: { now })
        let made = store.create(title: "Nowhere", tags: [])
        store.pin(id: made.id, now: now)
        #expect(store.activePin(now: now) != nil, "the case needs the pin to be active")
        #expect(ComposePinnedTrip.offered(by: store, now: now) == nil)
        #expect(
            ComposePinnedTrip(
                record: CollectionRecord(
                    id: UUID(), kind: .trip, title: "Blank", tags: [""], order: 0,
                    createdAt: now)) == nil)
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

    @Test("the timeline's sheet shows the chip for an active pin and not for an expired one")
    func timelineSheetFollowsThePin() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let store = CollectionStore(identity: alice, root: root, now: { now })
        store.pin(id: store.create(title: "Portugal 2026", tags: ["portugal2026"]).id, now: now)
        let until = try #require(store.records.first?.pinnedUntil)

        func sheet(at instant: Date) -> some View {
            TimelineView.editSheet(
                mode: .create(restoring: nil), isAsking: false, failure: nil,
                pinnedTrip: ComposePinnedTrip.offered(by: store, now: instant),
                send: { _ in }, submit: { _ in .saved })
        }
        #expect(chipShown(ScreenProbe.labels(of: sheet(at: now))))
        #expect(
            !chipShown(ScreenProbe.labels(of: sheet(at: until))), "an expired pin showed a chip")
    }

    @Test("Post sends the tag line; after the x it does not; a new sheet has the chip back")
    func postCarriesTheTag() async {
        let log = PostLog()
        let (posted, removed, postedAgain, waits) = await PressProbe.withScreen(
            sheet("Lisbon at dusk", pinnedTrip: trip) { await log.take($0) },
            height: 852
        ) { screen in
            let posted = screen.press("Post")
            let sentOnce = await screen.until { log.sent.count == 1 }
            let removed = screen.press("Remove trip tag")
            let chipGone = await screen.until { !screen.says("Pinned trip") }
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
            let sentOnce = await screen.until { log.sent.count == 1 }
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
                let ok = await TimelineView.enqueue(submission, into: outbox)
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
                submission, restoring: nil, accountDefault: .public,
                resubmit: { _, _ in .accepted },
                enqueue: { await TimelineView.enqueue($0, into: outbox) })
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
                await screen.settle(until: { !screen.says("Pinned trip") })
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

    @Test("with no trip pinned, the new memo states no visibility and the account default applies")
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
        #expect(body["visibility"] == nil, "a visibility was stated where the default applies")
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
        #expect(body["visibility"] == nil, "a visibility was stated where the default applies")
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
                submission, restoring: nil, accountDefault: .private,
                resubmit: { _, _ in .accepted },
                enqueue: { await TimelineView.enqueue($0, into: queue) })
            #expect(outcome == .saved)
            let body = try await createBody(http)
            #expect(body["content"] as? String == content, "positive control: body was read")
            #expect(body["visibility"] as? String == "PUBLIC")
        }
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
