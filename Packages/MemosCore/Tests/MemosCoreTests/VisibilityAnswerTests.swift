import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

/// The memo a visibility change was answered with, and where the viewer's Info sheet keeps it
/// (MEMNG-970): the timeline's own line hands it back, and the viewer's context store holds it as
/// the memo's truth, fenced by the session that issued the change and by the server's write stamp.
@MainActor
@Suite("Visibility answer: the memo the server answered a change with", .timeLimit(.minutes(1)))
struct VisibilityAnswerTests {
    nonisolated private static let patch = "patch_memo_api_memos__uid__patch"
    nonisolated private static let earlier = "2026-08-23T09:00:00.443000Z"
    nonisolated private static let later = "2026-08-23T10:00:00.443000Z"

    /// A server holding memo "m1": a read answers it at `start`; a PATCH answers it at the
    /// audience the body asked for, written `later`. Every PATCH's visibility is kept in order.
    private static func server(
        start: String = "PUBLIC", sent: Box<[String]>, gate: AsyncStream<Void>? = nil
    ) -> any APIProtocol {
        Stub.client { _, body, operation in
            guard operation == patch else {
                return Stub.json(Stub.memo(uid: "m1", visibility: start, updatedAt: earlier))
            }
            let visibility = try await Stub.body(body)["visibility"] as? String ?? "absent"
            sent.value.append(visibility)
            if let gate { for await _ in gate { break } }
            return Stub.json(Stub.memo(uid: "m1", visibility: visibility, updatedAt: later))
        }
    }

    private static func memo(_ visibility: MemoVisibility, at stamp: TimeInterval) -> Memo {
        Memo(
            uid: "m1", owner: "fabian", mine: true, content: "hello", visibility: visibility,
            pinned: false, createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: stamp))
    }

    @Test("a change to a memo this list does not hold is ONE PATCH, answered with the memo")
    func answerCarriesThePatchedMemo() async throws {
        let sent = Box<[String]>([])
        let handle = SessionHandle(client: Self.server(sent: sent), generation: 1)
        let store = TimelineStore()

        let answer = await store.setVisibilityAnswering(
            .cleared(.private, from: .public), uid: "m1", using: handle, baseURL: Stub.baseURL)

        #expect(sent.value == ["PRIVATE"])
        #expect(answer.outcome == .saved)
        let memo = try #require(answer.memo, "the server's memo was not handed back")
        #expect(memo.uid == "m1" && memo.visibility == .private)
        #expect(store.memos.isEmpty, "a memo outside the list was inserted into it")
    }

    @Test("two identical changes overlapping are one PATCH, and both callers get its memo")
    func joinedCallerGetsTheSameMemo() async throws {
        let sent = Box<[String]>([])
        let gate = AsyncStream<Void>.makeStream()
        let handle = SessionHandle(
            client: Self.server(sent: sent, gate: gate.stream), generation: 1)
        let store = TimelineStore()
        let change = VisibilityChange.cleared(.private, from: .public)

        let first = Task {
            await store.setVisibilityAnswering(
                change, uid: "m1", using: handle, baseURL: Stub.baseURL)
        }
        let second = Task {
            await store.setVisibilityAnswering(
                change, uid: "m1", using: handle, baseURL: Stub.baseURL)
        }
        while sent.value.isEmpty { await Task.yield() }
        gate.continuation.yield()
        gate.continuation.finish()
        let answers = [await first.value, await second.value]

        #expect(sent.value == ["PRIVATE"], "the joined change reached the wire again")
        #expect(answers[0] == answers[1])
        #expect(answers[1].memo?.visibility == .private)
    }

    @Test("an answer is held as the memo's truth for the viewer, over the memo it read")
    func answerIsHeld() async {
        let sent = Box<[String]>([])
        let handle = SessionHandle(client: Self.server(sent: sent), generation: 1)
        let context = MediaContextStore()
        await context.loadMemo(uid: "m1", using: handle, baseURL: Stub.baseURL)
        #expect(context.memo("m1")?.visibility == .public, "control: the read was not held")

        context.adoptAnswer(Self.memo(.private, at: 2_000_000_000), issuedUnder: handle)

        #expect(context.memo("m1")?.visibility == .private, "the answer was not held")
    }

    @Test("an answer issued under a session that has gone lands nowhere")
    func staleSessionAnswerLandsNowhere() async {
        let sent = Box<[String]>([])
        let client = Self.server(sent: sent)
        let departed = SessionHandle(client: client, generation: 1)
        let current = SessionHandle(client: client, generation: 2)
        let session = TripTestSession(for: current)
        let context = MediaContextStore()
        context.reports(to: session)
        await context.loadMemo(uid: "m1", using: current, baseURL: Stub.baseURL)
        #expect(context.memo("m1")?.visibility == .public, "control: the read was not held")

        context.adoptAnswer(Self.memo(.private, at: 2_000_000_000), issuedUnder: departed)

        #expect(context.memo("m1")?.visibility == .public, "a departed session's answer landed")
    }

    @Test("an answer the server wrote before the memo held cannot put the older audience back")
    func olderAnswerDoesNotReplaceNewer() {
        let sent = Box<[String]>([])
        let handle = SessionHandle(client: Self.server(sent: sent), generation: 1)
        let context = MediaContextStore()

        context.adoptAnswer(Self.memo(.private, at: 2_000_000_000), issuedUnder: handle)
        context.adoptAnswer(Self.memo(.public, at: 1_000_000_000), issuedUnder: handle)
        #expect(context.memo("m1")?.visibility == .private, "an outlived answer resurrected")

        // Control: an answer written at or after the held one is taken.
        context.adoptAnswer(Self.memo(.protected, at: 2_000_000_000), issuedUnder: handle)
        #expect(context.memo("m1")?.visibility == .protected)
    }
}
