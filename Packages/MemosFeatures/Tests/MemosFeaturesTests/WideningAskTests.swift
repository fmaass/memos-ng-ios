import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing

@testable import MemosFeatures

/// The server a visibility change talks to: one memo "m1" to load, at `start`, and every PATCH body
/// kept as it was sent and answered with the memo at the audience it asked for. While `holding` is
/// set a PATCH waits before it answers, so a test can queue a second change behind the first.
nonisolated private final class AudienceServer: ClientTransport, @unchecked Sendable {
    static let list = "list_memos_api_memos_get"
    static let patch = "patch_memo_api_memos__uid__patch"

    private let lock = NSLock()
    private let start: String
    private var sent: [String] = []
    private var held = false

    init(start: String) { self.start = start }

    /// The visibility each PATCH carried, in the order they reached the wire.
    var visibilities: [String] { lock.withLock { sent } }
    var holding: Bool {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }

    private static func memo(_ visibility: String) -> String {
        """
        {"uid":"m1","owner":"fabian","mine":true,"content":"Lisbon at dusk",\
        "visibility":"\(visibility)","pinned":false,"created_at":"2026-08-23T09:00:00Z",\
        "updated_at":"2026-08-23T09:00:00.443000Z","archived_at":null,"tags":[],\
        "attachments":[]}
        """
    }

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
            let page = #"{"items":[\#(Self.memo(start))],"nextCursor":null,"totalCount":null}"#
            return (response, HTTPBody(page))
        case Self.patch:
            let data = try await Data(collecting: body ?? HTTPBody(), upTo: 1 << 20)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let visibility = object?["visibility"] as? String ?? "absent"
            lock.withLock { sent.append(visibility) }
            while holding { try await Task.sleep(for: .milliseconds(1)) }
            return (response, HTTPBody(Self.memo(visibility)))
        default:
            return (HTTPResponse(status: .internalServerError), nil)
        }
    }
}

/// The confirm/dismiss decision both screens hand a widening to (MEMNG-981), driven the way the
/// screens drive it and sent through the real store and the real generated client.
@MainActor
@Suite("Widening: one conversation for the edit sheet and the long press")
struct WideningAskTests {
    private static let base = URL(string: "https://memos.example.invalid")!

    private static func handle(_ server: AudienceServer) -> SessionHandle {
        SessionHandle(
            client: APIClientFactory.make(
                configuration: ServerConfiguration(baseURL: base),
                token: { "memos_pat_widening" }, transport: server),
            generation: 1)
    }

    private static func loaded(_ server: AudienceServer) async -> TimelineStore {
        let store = TimelineStore()
        await store.refresh(using: handle(server), baseURL: base)
        return store
    }

    /// What both screens do with an answer: send the yes, and hear what the store said.
    private static func act(
        on answer: WideningAsk.Send?, _ ask: inout WideningAsk, in store: TimelineStore,
        server: AudienceServer
    ) async {
        guard let answer else { return }
        let outcome = await store.setVisibility(
            answer.change, uid: answer.uid, using: handle(server), baseURL: base)
        ask.heard(outcome, on: answer.uid)
    }

    @Test("a narrowing pick goes as it is, the memo's own audience sends nothing, no question")
    func narrowingAndUnchangedPicks() throws {
        var ask = WideningAsk()
        guard case .send(let change?) = ask.pick(.private, from: .public, on: "m1") else {
            Issue.record("Public → Private did not go")
            return
        }
        #expect(change.to == .private && !change.confirmed)
        let unchanged = ask.pick(.public, from: .public, on: "m1")
        #expect(unchanged == .send(nil))
        #expect(ask.pending == nil)
    }

    @Test("a dismissed widening sends nothing")
    func dismissSendsNothing() async throws {
        let server = AudienceServer(start: "PRIVATE")
        let store = await Self.loaded(server)
        var ask = WideningAsk()
        let next = ask.pick(.public, from: .private, on: "m1")
        #expect(next == .asking)
        let shown = try #require(ask.pending)
        #expect(ask.title == "Make this memo \(MemoVisibility.public.label)?")
        let answer = ask.answer(shown, confirmed: false)
        await Self.act(on: answer, &ask, in: store, server: server)
        #expect(answer == nil, "a dismissal answered with a change")
        #expect(ask.pending == nil, "the question is still up after its dismissal")
        #expect(server.visibilities.isEmpty, "a dismissal reached the wire: \(server.visibilities)")
        #expect(store.memos.first?.visibility == .private)
    }

    @Test("the yes tapped twice is ONE PATCH")
    func confirmTwiceIsOnePatch() async throws {
        let server = AudienceServer(start: "PRIVATE")
        let store = await Self.loaded(server)
        var ask = WideningAsk()
        let next = ask.pick(.public, from: .private, on: "m1")
        #expect(next == .asking)
        let shown = try #require(ask.pending)
        // Two taps in one frame: both answer the question that was on screen.
        let first = ask.answer(shown, confirmed: true)
        let second = ask.answer(shown, confirmed: true)
        await Self.act(on: first, &ask, in: store, server: server)
        await Self.act(on: second, &ask, in: store, server: server)
        #expect(first?.change.confirmed == true, "control: the yes sent the confirmed change")
        #expect(server.visibilities == ["PUBLIC"], "the yes went \(server.visibilities.count)×")
        #expect(store.memos.first?.visibility == .public)
    }

    @Test("a yes from a dismissed presentation does not answer the same question asked again")
    func staleYesAnswersNothing() async throws {
        let server = AudienceServer(start: "PRIVATE")
        let store = await Self.loaded(server)
        var ask = WideningAsk()
        #expect(ask.pick(.public, from: .private, on: "m1") == .asking)
        let dismissed = try #require(ask.pending)
        #expect(ask.answer(dismissed, confirmed: false) == nil, "control: dismissal sends nothing")
        // The same memo's store answer puts the identical question up again (MEMNG-1033).
        let question = dismissed.question
        ask.heard(.ask(question), on: "m1")
        let shown = try #require(ask.pending)
        // The dismissed alert's yes arrives late: it is not an answer to the one now up.
        let stale = ask.answer(dismissed, confirmed: true)
        #expect(stale == nil, "a dismissed presentation's yes answered the question re-asked")
        #expect(ask.pending == shown, "a stale yes took the question on screen down")
        let yes = ask.answer(shown, confirmed: true)
        await Self.act(on: stale, &ask, in: store, server: server)
        await Self.act(on: yes, &ask, in: store, server: server)
        #expect(yes == WideningAsk.Send(uid: "m1", change: question.confirmed()))
        #expect(server.visibilities == ["PUBLIC"], "the yes went \(server.visibilities.count)×")
    }

    @Test("a change that became a widening while it queued is asked again; its yes is one PATCH")
    func queuedWideningIsReasked() async throws {
        let server = AudienceServer(start: "PUBLIC")
        let store = await Self.loaded(server)
        var ask = WideningAsk()
        // Both picked while the row read Public: two narrowings, no question.
        guard case .send(let toPrivate?) = ask.pick(.private, from: .public, on: "m1"),
            case .send(let toUs?) = ask.pick(.protected, from: .public, on: "m1")
        else {
            Issue.record("a narrowing from Public asked")
            return
        }
        server.holding = true
        let first = Task {
            await store.setVisibility(
                toPrivate, uid: "m1", using: Self.handle(server), baseURL: Self.base)
        }
        while server.visibilities.isEmpty { await Task.yield() }
        let second = Task {
            await store.setVisibility(
                toUs, uid: "m1", using: Self.handle(server), baseURL: Self.base)
        }
        try? await Task.sleep(for: .milliseconds(100))
        server.holding = false
        #expect(await first.value.isSaved, "control: the narrowing landed")
        let outcome = await second.value
        ask.heard(outcome, on: "m1")
        let shown = try #require(ask.pending, "Private → Just us was not asked again")
        #expect(shown.question.from == .private && shown.question.to == .protected)
        #expect(server.visibilities == ["PRIVATE"], "Just us went out unconfirmed")
        let yes = ask.answer(shown, confirmed: true)
        await Self.act(on: yes, &ask, in: store, server: server)
        #expect(server.visibilities == ["PRIVATE", "PROTECTED"])
        #expect(ask.pending == nil)
    }

    // MARK: - one question at a time, none lost (MEMNG-1193)

    /// The screen's state, as the `@State` behind `$widening` holds it.
    private final class Held {
        var ask = WideningAsk()
    }

    private struct NotAWidening: Error {}

    private static func question(_ from: MemoVisibility, _ to: MemoVisibility) throws
        -> VisibilityChange.Question
    {
        guard case .ask(let question) = VisibilityChange.propose(to, from: from) else {
            throw NotAWidening()
        }
        return question
    }

    @Test("another memo's question waits behind the one on screen and is asked after it")
    func anotherMemosQuestionQueues() throws {
        var ask = WideningAsk()
        #expect(ask.pick(.public, from: .private, on: "m1") == .asking)
        let first = try #require(ask.pending)
        // The store answers a change on another memo with a question while the first is up.
        let second = try Self.question(.private, .protected)
        ask.heard(.ask(second), on: "m2")
        #expect(ask.pending == first, "another memo's question replaced the one on screen")
        #expect(ask.answer(first, confirmed: false) == nil, "control: a dismissal sends nothing")
        let next = try #require(ask.pending, "the queued question was lost")
        #expect(next.uid == "m2" && next.question == second)
        #expect(next.id != first.id, "the queued question is its own presentation")
        // Its yes is its own memo's change, exactly once.
        let yes = ask.answer(next, confirmed: true)
        #expect(yes == WideningAsk.Send(uid: "m2", change: second.confirmed()))
        #expect(ask.answer(next, confirmed: true) == nil, "the yes was answered twice")
        #expect(ask.pending == nil)
    }

    @Test("one question per memo: none asked twice, a newer one takes a waiting one's place")
    func queueHoldsOneQuestionPerMemo() throws {
        var ask = WideningAsk()
        #expect(ask.pick(.public, from: .private, on: "m1") == .asking)
        let first = try #require(ask.pending)
        // The same question for the memo on screen, heard again, is not asked a second time.
        ask.heard(.ask(first.question), on: "m1")
        // Two questions for another memo while the first is up: the newer one waits, alone.
        ask.heard(.ask(try Self.question(.private, .protected)), on: "m2")
        let newer = try Self.question(.private, .public)
        ask.heard(.ask(newer), on: "m2")
        #expect(ask.answer(first, confirmed: false) == nil, "control: a dismissal sends nothing")
        let next = try #require(ask.pending, "the waiting question was lost")
        #expect(next.uid == "m2" && next.question == newer, "the older question was asked")
        #expect(ask.answer(next, confirmed: false) == nil)
        #expect(ask.pending == nil, "a memo's question was asked twice")
    }

    @Test("a newer question for the memo on screen supersedes it; the old yes sends nothing")
    func newerQuestionSupersedesTheOneOnScreen() throws {
        var ask = WideningAsk()
        #expect(ask.pick(.protected, from: .private, on: "m1") == .asking)
        let first = try #require(ask.pending)
        let newer = try Self.question(.private, .public)
        #expect(first.question != newer, "control: two different questions for one memo")
        ask.heard(.ask(newer), on: "m1")
        let shown = try #require(ask.pending, "the newer question was not put up")
        #expect(shown.uid == "m1" && shown.question == newer, "the older question stayed up")
        #expect(shown.id != first.id, "the newer question is its own presentation")
        #expect(ask.answer(first, confirmed: true) == nil, "the superseded alert's yes was sent")
        let yes = ask.answer(shown, confirmed: true)
        #expect(yes == WideningAsk.Send(uid: "m1", change: newer.confirmed()))
        #expect(ask.pending == nil, "the superseded question was still in line")
    }

    @Test("the alert's dismissal answers the presentation it showed, not the one promoted after")
    func dismissalAnswersItsOwnPresentation() throws {
        let held = Held()
        let state = Binding(get: { held.ask }, set: { held.ask = $0 })
        #expect(held.ask.pick(.public, from: .private, on: "m1") == .asking)
        let first = try #require(held.ask.pending)
        held.ask.heard(.ask(try Self.question(.private, .protected)), on: "m2")
        // The alert as rendered for the first question.
        let presented = WideningAsk.presented(state)
        #expect(presented.wrappedValue, "control: the first question is up")
        // Its yes is tapped; the answer promotes the queued question; then the alert writes its
        // own dismissal through the binding it was rendered with.
        let yes = held.ask.answer(first, confirmed: true)
        #expect(yes?.uid == "m1", "control: the yes answered the first question")
        let promoted = try #require(held.ask.pending, "the queued question was not promoted")
        presented.wrappedValue = false
        #expect(held.ask.pending == promoted, "the first alert's dismissal took the next one down")
        #expect(presented.wrappedValue, "the next question is not up")
        // The next render's alert, dismissed: that one, and only that one, goes, sending nothing.
        let next = WideningAsk.presented(state)
        next.wrappedValue = false
        #expect(held.ask.pending == nil, "a dismissal left its own question up")
        #expect(held.ask.answer(promoted, confirmed: true) == nil, "a dismissed question sent")
    }
}
