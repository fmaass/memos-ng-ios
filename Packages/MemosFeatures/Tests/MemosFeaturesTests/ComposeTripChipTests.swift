import Foundation
import MemosCore
import MemosOutbox
import SwiftUI
import Testing

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
        let (posted, removed, postedAgain) = await PressProbe.withScreen(
            sheet("Lisbon at dusk", pinnedTrip: trip) { await log.take($0) },
            height: 852
        ) { screen in
            let posted = screen.press("Post")
            await screen.settle(until: { log.sent.count == 1 })
            let removed = screen.press("Remove trip tag")
            await screen.settle(until: { !screen.says("Pinned trip") })
            let postedAgain = screen.press("Post")
            await screen.settle(until: { log.sent.count == 2 })
            return (posted, removed, postedAgain)
        }
        #expect(posted && removed && postedAgain)
        #expect(log.sent.map(\.content) == ["Lisbon at dusk\n#portugal2026", "Lisbon at dusk"])

        let again = ScreenProbe.labels(of: sheet("Lisbon at dusk", pinnedTrip: trip))
        #expect(chipShown(again), "a new sheet with the same pin did not show the chip")
    }

    @Test("a failed post tried again sends the tag line once, from the unchanged words")
    func retryDoesNotDoubleTheLine() async {
        let log = PostLog(answers: [.failed(.transport(sent: false)), .saved])
        let (wordsShown, lineShown) = await PressProbe.withScreen(
            sheet("Lisbon at dusk", pinnedTrip: trip) { await log.take($0) },
            height: 852
        ) { screen in
            _ = screen.press("Post")
            await screen.settle(until: { log.sent.count == 1 })
            await screen.settle()
            // What the editor shows after the failure: the words as typed, and no tag line.
            let shown = (screen.says("Lisbon at dusk"), screen.says("#portugal2026"))
            _ = screen.press("Post")
            await screen.settle(until: { log.sent.count == 2 })
            return shown
        }
        #expect(wordsShown, "the editor's words could not be read: the next check proves nothing")
        #expect(!lineShown, "the tag line was written into the editor")
        let once = "Lisbon at dusk\n#portugal2026"
        #expect(log.sent.map(\.content) == [once, once])
    }

    @Test("a restored capture already carrying the tag is posted as it stands")
    func restoredPostIsNotDoubled() async {
        let log = PostLog()
        await PressProbe.withScreen(
            sheet("Lisbon\n#portugal2026", pinnedTrip: trip) { await log.take($0) },
            height: 852
        ) { screen in
            _ = screen.press("Post")
            await screen.settle(until: { log.sent.count == 1 })
        }
        #expect(log.sent.map(\.content) == ["Lisbon\n#portugal2026"])
    }

    // MARK: - The wire

    @Test("the sheet's Post, through the timeline's enqueue and the real outbox, reaches the wire")
    func wireBodyCarriesTheTag() async throws {
        let http = RecordingHTTP()
        let credentials = SignedIn()
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { credentials.stillCurrent(epoch: $0) })
        let outbox = Outbox(
            repository: repository,
            credentials: credentials,
            http: http,
            scheduler: NoChunks(),
            completion: MemoCompletionEndpoint(http: http),
            network: OnWiFi(),
            preferences: UploadPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
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
