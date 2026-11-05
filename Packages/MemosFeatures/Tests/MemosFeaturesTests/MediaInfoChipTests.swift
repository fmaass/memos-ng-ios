import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

@testable import MemosFeatures

/// A server holding memo "m1": the list and a read answer it at `start`, owned by the reader when
/// `mine`; a PATCH answers as `answers` scripts it, by default at the audience its body asked
/// for, written an hour later. While `holding` is set a PATCH waits before it answers.
nonisolated private final class ChipServer: ClientTransport, @unchecked Sendable {
    /// How a PATCH is answered (MEMNG-1034).
    nonisolated enum PatchAnswer: Sendable {
        /// The memo at the audience the body asked for, written an hour after the list's stamp.
        case echo
        /// The memo at this audience and this stamp, whatever the body asked for.
        case memo(visibility: String, updated: String)
        /// This status and no body.
        case status(Int)
        /// No answer at all: the device is offline.
        case offline
    }

    /// The stamp the list and a read carry.
    static let listed = "2026-08-23T09:00:00.443000Z"
    /// The stamp an echoed PATCH answer carries.
    static let anHourLater = "2026-08-23T10:00:00.443000Z"

    private let lock = NSLock()
    private let start: String
    private let mine: Bool
    private var sent: [String] = []
    private var held = false
    private var script: [PatchAnswer] = []

    init(start: String, mine: Bool = true) {
        self.start = start
        self.mine = mine
    }

    var visibilities: [String] { lock.withLock { sent } }
    var holding: Bool {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
    /// The answers to the next PATCHes, in order; once they run out every PATCH is `.echo`.
    var answers: [PatchAnswer] {
        get { lock.withLock { script } }
        set { lock.withLock { script = newValue } }
    }

    func memo(_ visibility: String, updated: String) -> String {
        """
        {"uid":"m1","owner":"fabian","mine":\(mine),"content":"Lisbon at dusk",\
        "visibility":"\(visibility)","pinned":false,"created_at":"2026-08-23T09:00:00Z",\
        "updated_at":"\(updated)","archived_at":null,"tags":[],"attachments":[]}
        """
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        let earlier = Self.listed
        switch operationID {
        case "list_memos_api_memos_get":
            let item = memo(start, updated: earlier)
            let page = #"{"items":[\#(item)],"nextCursor":null,"totalCount":null}"#
            return (response, HTTPBody(page))
        case "get_memo_api_memos__uid__get":
            return (response, HTTPBody(memo(start, updated: earlier)))
        case "patch_memo_api_memos__uid__patch":
            let data = try await Data(collecting: body ?? HTTPBody(), upTo: 1 << 20)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let visibility = object?["visibility"] as? String ?? "absent"
            let answer: PatchAnswer = lock.withLock {
                sent.append(visibility)
                return script.isEmpty ? .echo : script.removeFirst()
            }
            while holding { try await Task.sleep(for: .milliseconds(1)) }
            switch answer {
            case .echo:
                return (response, HTTPBody(memo(visibility, updated: Self.anHourLater)))
            case .memo(let answered, let updated):
                return (response, HTTPBody(memo(answered, updated: updated)))
            case .status(let code):
                return (HTTPResponse(status: .init(code: code)), nil)
            case .offline:
                throw URLError(.notConnectedToInternet)
            }
        default:
            return (HTTPResponse(status: .internalServerError), nil)
        }
    }
}

/// The Info sheet's Visibility chip (MEMNG-970), driven the way the sheet drives it — the chip's
/// state from the card, a pick through `WideningAsk`, the send through the real timeline store's
/// line and the real generated client — and read back from where the sheet reads its memo.
@MainActor
@Suite("Info sheet: the Visibility chip", .timeLimit(.minutes(1)))
struct MediaInfoChipTests {
    private static let base = URL(string: "https://memos.example.invalid")!

    private static func handle(_ server: ChipServer) -> SessionHandle {
        SessionHandle(
            client: APIClientFactory.make(
                configuration: ServerConfiguration(baseURL: base),
                token: { "memos_pat_chip" }, transport: server),
            generation: 1)
    }

    /// The card the sheet draws for a looked-up memo, as the sheet reads it.
    private static func lookedUp(_ context: MediaContextStore) -> MediaInfoRows.MemoCard? {
        let link = MediaViewerContext.MemoLink.lookup("m1")
        return MediaInfoRows.memoCard(link, looked: MediaInfoRows.held(link, in: context))
    }

    /// A narrowing as the rule proposes it: it goes as it is, no question asked.
    private static func narrowing(_ to: MemoVisibility, from: MemoVisibility) -> VisibilityChange {
        guard case .ready(let change) = VisibilityChange.propose(to, from: from) else {
            fatalError("\(from) → \(to) is not a narrowing")
        }
        return change
    }

    private static func carried(_ visibility: MemoVisibility) -> Memo {
        Memo(
            uid: "m1", owner: "fabian", mine: true, content: "Lisbon at dusk",
            visibility: visibility, pinned: false, createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1_787_475_600))
    }

    @Test("the chip draws the memo's visibility, and is inert for a memo that is not the person's")
    func inertForAnotherPersonsMemo() async throws {
        for mine in [false, true] {
            let server = ChipServer(start: "PUBLIC", mine: mine)
            let context = MediaContextStore()
            await context.loadMemo(uid: "m1", using: Self.handle(server), baseURL: Self.base)
            let card = try #require(Self.lookedUp(context))
            let chip = MediaInfoRows.chip(card, canChange: true)
            #expect(chip == (mine ? .menu(.public) : .inert(.public)), "mine \(mine)")
            // With no line to send through, even the person's own memo is inert.
            #expect(MediaInfoRows.chip(card, canChange: false) == .inert(.public))
        }
    }

    @Test("choosing Private PATCHes the memo and the chip shows the server's answer")
    func privateGoesAndTheChipReflectsTheAnswer() async throws {
        let server = ChipServer(start: "PUBLIC")
        let handle = Self.handle(server)
        let context = MediaContextStore()
        // The Library's case: a memo the timeline does not hold, looked up by the sheet.
        let timeline = TimelineStore()
        await context.loadMemo(uid: "m1", using: handle, baseURL: Self.base)
        let card = try #require(Self.lookedUp(context))
        #expect(MediaInfoRows.chip(card, canChange: true) == .menu(.public))

        var ask = WideningAsk()
        guard case .send(let change?) = ask.pick(.private, from: card.visibility, on: card.uid)
        else {
            Issue.record("Public → Private did not go at once")
            return
        }
        let outcome = await MediaInfoSheet.sendVisibility(
            change, uid: card.uid, through: timeline, holding: context, using: handle,
            baseURL: Self.base)

        #expect(outcome == .saved)
        #expect(server.visibilities == ["PRIVATE"])
        let after = try #require(Self.lookedUp(context))
        #expect(MediaInfoRows.chip(after, canChange: true) == .menu(.private))
    }

    @Test("a widening asks once; the dismissal sends nothing, the yes is one PATCH")
    func wideningAsksOnce() async throws {
        let server = ChipServer(start: "PRIVATE")
        let handle = Self.handle(server)
        let context = MediaContextStore()
        let timeline = TimelineStore()
        await context.loadMemo(uid: "m1", using: handle, baseURL: Self.base)
        let card = try #require(Self.lookedUp(context))

        var ask = WideningAsk()
        let first = ask.pick(.public, from: card.visibility, on: card.uid)
        #expect(first == .asking)
        let dismissed = try #require(ask.pending)
        let dismissal = ask.answer(dismissed, confirmed: false)
        #expect(dismissal == nil)
        #expect(server.visibilities.isEmpty, "a dismissal reached the wire")

        let again = ask.pick(.public, from: card.visibility, on: card.uid)
        #expect(again == .asking)
        let shown = try #require(ask.pending)
        let answered = ask.answer(shown, confirmed: true)
        let twice = ask.answer(shown, confirmed: true)
        let yes = try #require(answered)
        #expect(twice == nil, "the yes answered twice")
        _ = await MediaInfoSheet.sendVisibility(
            yes.change, uid: yes.uid, through: timeline, holding: context, using: handle,
            baseURL: Self.base)
        #expect(server.visibilities == ["PUBLIC"])
        #expect(Self.lookedUp(context)?.visibility == .public)
    }

    @Test("a carried memo's chip shows the answer over the copy it was opened with")
    func carriedMemoShowsTheAnswer() async throws {
        let server = ChipServer(start: "PUBLIC")
        let handle = Self.handle(server)
        let context = MediaContextStore()
        let timeline = TimelineStore()
        let memo = Self.carried(.public)
        let link = MediaViewerContext.MemoLink.carried(memo)
        #expect(MediaInfoRows.held(link, in: context) == nil, "control: nothing held yet")

        _ = await MediaInfoSheet.sendVisibility(
            Self.narrowing(.private, from: .public), uid: "m1", through: timeline,
            holding: context, using: handle, baseURL: Self.base)

        let card = MediaInfoRows.memoCard(link, looked: MediaInfoRows.held(link, in: context))
        #expect(card?.visibility == .private, "the chip still shows the carried copy")
    }

    @Test("a carried copy the server wrote after the held answer is the one shown")
    func newerCarriedCopyWins() async throws {
        let server = ChipServer(start: "PUBLIC")
        let handle = Self.handle(server)
        let context = MediaContextStore()
        _ = await MediaInfoSheet.sendVisibility(
            Self.narrowing(.private, from: .public), uid: "m1", through: TimelineStore(),
            holding: context, using: handle, baseURL: Self.base)
        var newer = Self.carried(.protected)
        newer.updatedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let link = MediaViewerContext.MemoLink.carried(newer)

        let card = MediaInfoRows.memoCard(link, looked: MediaInfoRows.held(link, in: context))
        #expect(card?.visibility == .protected, "an older answer hid the list's newer copy")
        #expect(card?.mine == true)
    }

    @Test("a change that became a widening while it queued comes back as its question")
    func queuedWideningComesBackAsAQuestion() async throws {
        let server = ChipServer(start: "PUBLIC")
        let handle = Self.handle(server)
        let context = MediaContextStore()
        let timeline = TimelineStore()
        await timeline.refresh(using: handle, baseURL: Self.base)
        server.holding = true
        let first = Task {
            await MediaInfoSheet.sendVisibility(
                Self.narrowing(.private, from: .public), uid: "m1", through: timeline,
                holding: context, using: handle, baseURL: Self.base)
        }
        while server.visibilities.isEmpty { await Task.yield() }
        // Proposed over Public, a narrowing; reached after Private landed, a widening.
        let second = Task {
            await MediaInfoSheet.sendVisibility(
                Self.narrowing(.protected, from: .public), uid: "m1", through: timeline,
                holding: context, using: handle, baseURL: Self.base)
        }
        try? await Task.sleep(for: .milliseconds(100))
        server.holding = false
        #expect(await first.value == .saved, "control: the narrowing landed")
        guard case .ask(let question) = await second.value else {
            Issue.record("Private → Just us went out, or failed, instead of asking")
            return
        }
        #expect(question.from == .private && question.to == .protected)
        #expect(server.visibilities == ["PRIVATE"])
    }

    @Test("an answer issued under a session that has gone never reaches the chip")
    func departedSessionAnswerLandsNowhere() async throws {
        let server = ChipServer(start: "PUBLIC")
        let departed = Self.handle(server)
        let current = SessionHandle(client: departed.client, generation: 2)
        let session = TripMapReporter()
        session.activeHandle = current
        let context = MediaContextStore()
        context.reports(to: session)
        await context.loadMemo(uid: "m1", using: current, baseURL: Self.base)
        #expect(Self.lookedUp(context)?.visibility == .public, "control: the read was not held")

        _ = await MediaInfoSheet.sendVisibility(
            Self.narrowing(.private, from: .public), uid: "m1", through: TimelineStore(),
            holding: context, using: departed, baseURL: Self.base)

        #expect(Self.lookedUp(context)?.visibility == .public, "a departed session's answer landed")
    }

    @Test("an answer the server wrote before the memo held cannot put the older audience back")
    func outlivedAnswerDoesNotResurrect() async throws {
        let server = ChipServer(start: "PUBLIC")
        let handle = Self.handle(server)
        let context = MediaContextStore()
        var newer = Self.carried(.protected)
        newer.updatedAt = Date(timeIntervalSince1970: 1_900_000_000)
        context.adoptAnswer(newer, issuedUnder: handle)

        _ = await MediaInfoSheet.sendVisibility(
            Self.narrowing(.private, from: .public), uid: "m1", through: TimelineStore(),
            holding: context, using: handle, baseURL: Self.base)

        #expect(server.visibilities == ["PRIVATE"], "control: the change went")
        #expect(Self.lookedUp(context)?.visibility == .protected, "an outlived answer landed")
    }

    /// A pick of Private on the person's Public memo, sent the way the sheet sends it, with the
    /// sheet's line fed the outcome as the sheet feeds it.
    private static func pickPrivate(
        _ server: ChipServer, on context: MediaContextStore, line: inout MediaInfoSheet.ChipLine
    ) async throws -> ComposeOutcome {
        let handle = Self.handle(server)
        await context.loadMemo(uid: "m1", using: handle, baseURL: Self.base)
        let card = try #require(Self.lookedUp(context))
        var ask = WideningAsk()
        guard case .send(let change?) = ask.pick(.private, from: card.visibility, on: card.uid)
        else {
            Issue.record("Public → Private did not go at once")
            return .saved
        }
        let ticket = line.sending()
        let outcome = await MediaInfoSheet.sendVisibility(
            change, uid: card.uid, through: TimelineStore(), holding: context, using: handle,
            baseURL: Self.base)
        ask.heard(outcome, on: card.uid)
        #expect(ask.pending == nil, "a failure put a question up")
        line.heard(outcome, for: ticket)
        return outcome
    }

    @Test("a refused, failed or unheard change is told in the sheet; the chip keeps the audience")
    func failedChangeIsToldInTheSheet() async throws {
        let cases: [(ChipServer.PatchAnswer, ComposeFailure, String)] = [
            (.status(403), .rejection, "4xx"),
            (.status(500), .serverFailure, "5xx"),
            (.offline, .transport(sent: true), "offline"),
        ]
        for (answer, failure, label) in cases {
            let server = ChipServer(start: "PUBLIC")
            server.answers = [answer]
            let context = MediaContextStore()
            var line = MediaInfoSheet.ChipLine()

            let outcome = try await Self.pickPrivate(server, on: context, line: &line)

            #expect(server.visibilities == ["PRIVATE"], "control: the change went (\(label))")
            #expect(outcome == .failed(failure), "\(label)")
            let said = ComposeFailurePresentation.sentence(for: failure)
            #expect(MediaInfoSheet.failureLine(for: outcome) == said, "\(label)")
            #expect(line.sentence == said, "the sheet said nothing (\(label))")
            let card = try #require(Self.lookedUp(context))
            #expect(MediaInfoRows.chip(card, canChange: true) == .menu(.public), "\(label)")
        }
    }

    @Test("every outcome category has its line: a failure its sentence, a save and a question none")
    func everyOutcomeHasItsLine() throws {
        #expect(MediaInfoSheet.failureLine(for: .saved) == nil)
        guard case .ask(let question) = VisibilityChange.propose(.public, from: .private) else {
            Issue.record("Private → Public did not ask")
            return
        }
        #expect(MediaInfoSheet.failureLine(for: .ask(question)) == nil)
        let failures: [ComposeFailure] = [
            .transport(sent: false), .transport(sent: true), .authorization, .storage, .rejection,
            .serverFailure, .defaultVisibilityUnknown,
        ]
        for failure in failures {
            let said = MediaInfoSheet.failureLine(for: .failed(failure))
            #expect(said == ComposeFailurePresentation.sentence(for: failure), "\(failure)")
            #expect(said?.isEmpty == false, "\(failure)")
        }
    }

    @Test("a failed change's line goes once the next change goes, and that change's answer shows")
    func nextChangeClearsTheLine() async throws {
        let server = ChipServer(start: "PUBLIC")
        server.answers = [.status(500)]
        let context = MediaContextStore()
        var line = MediaInfoSheet.ChipLine()
        let failed = try await Self.pickPrivate(server, on: context, line: &line)
        #expect(failed == .failed(.serverFailure), "control: the first change failed")
        #expect(line.sentence != nil, "control: the failure was told")

        let again = try await Self.pickPrivate(server, on: context, line: &line)

        #expect(again == .saved)
        #expect(server.visibilities == ["PRIVATE", "PRIVATE"])
        #expect(line.sentence == nil, "the failure outlived the change that went")
        #expect(Self.lookedUp(context)?.visibility == .private)
    }

    @Test("the line speaks for the latest change only: an overtaken change's failure lands nowhere")
    func overtakenFailureLandsNowhere() {
        var line = MediaInfoSheet.ChipLine()
        let failing = line.sending()
        line.heard(.failed(.rejection), for: failing)
        #expect(line.sentence == ComposeFailurePresentation.sentence(for: .rejection))
        let earlier = line.sending()
        #expect(line.sentence == nil, "a change went and the old failure stayed up")
        let later = line.sending()
        line.heard(.saved, for: later)
        line.heard(.failed(.serverFailure), for: earlier)
        #expect(line.sentence == nil, "an overtaken change's failure landed over a later answer")
        line.heard(.failed(.storage), for: later)
        #expect(line.sentence == ComposeFailurePresentation.sentence(for: .storage), "control")
    }

    @Test("an answer stamped the same instant as the memo held is the one the chip shows")
    func tiedAnswerWins() async throws {
        let server = ChipServer(start: "PUBLIC")
        // The server's answer carries the very stamp the read did: equal is not older.
        server.answers = [.memo(visibility: "PRIVATE", updated: ChipServer.listed)]
        let context = MediaContextStore()
        var line = MediaInfoSheet.ChipLine()

        let outcome = try await Self.pickPrivate(server, on: context, line: &line)

        #expect(outcome == .saved)
        let card = try #require(Self.lookedUp(context))
        #expect(MediaInfoRows.chip(card, canChange: true) == .menu(.private), "a tie kept the read")
    }

    @Test("the chip shows the audience the server answered with, not the one that was picked")
    func answerNotSelectionIsShown() async throws {
        let server = ChipServer(start: "PUBLIC")
        server.answers = [.memo(visibility: "PROTECTED", updated: ChipServer.anHourLater)]
        let context = MediaContextStore()
        var line = MediaInfoSheet.ChipLine()

        let outcome = try await Self.pickPrivate(server, on: context, line: &line)

        #expect(outcome == .saved)
        #expect(server.visibilities == ["PRIVATE"], "control: Private was asked for")
        #expect(line.sentence == nil)
        let card = try #require(Self.lookedUp(context))
        #expect(MediaInfoRows.chip(card, canChange: true) == .menu(.protected), "the pick shown")
    }
}
