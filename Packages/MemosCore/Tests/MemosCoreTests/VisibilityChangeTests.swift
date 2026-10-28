import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let listMemosOperation = "list_memos_api_memos_get"
private let patchMemoOperation = "patch_memo_api_memos__uid__patch"

/// Keeps a request open until the test lets it go; called off the main actor by the transport.
private func held(until release: LockedValue<Bool>) async throws {
    while !release.get() {
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// The PATCH bodies a store actually built, in the order they reached the wire.
private final class PatchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []

    func record(_ body: [String: Any]) { lock.withLock { bodies.append(body) } }
    var all: [[String: Any]] { lock.withLock { bodies } }
}

/// MEMNG-969: narrowing goes on Save, widening asks once, an untouched audience is not restated,
/// and the rule lives in `VisibilityChange` for every store that sends one.
@MainActor
@Suite("Visibility changes: narrowing goes, widening asks once")
struct VisibilityChangeTests {
    private func server(
        rows: [String] = [Stub.memo(uid: "a", visibility: "PUBLIC")],
        answer: @escaping @Sendable () -> String = { Stub.memo(uid: "a") },
        release: LockedValue<Bool>? = nil
    ) -> (client: any APIProtocol, log: PatchLog) {
        let log = PatchLog()
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.page(rows))
            }
            log.record(Stub.object(try await Stub.bytes(body)))
            if let release { try await held(until: release) }
            return Stub.json(answer())
        }
        return (client, log)
    }

    // MARK: - the rule, every input category

    @Test("every move between audiences is classified: narrowing ready, widening asks")
    func everyPairIsClassified() {
        let order: [MemoVisibility] = [.private, .protected, .public]
        for (i, from) in order.enumerated() {
            for (j, to) in order.enumerated() {
                let proposal = VisibilityChange.propose(to, from: from)
                switch proposal {
                case .unchanged: #expect(i == j, "\(from)→\(to) called unchanged")
                case .ready(let change):
                    #expect(j < i, "\(from)→\(to) went without asking")
                    #expect(!change.widens)
                case .ask(let question):
                    #expect(j > i, "\(from)→\(to) asked although it narrows")
                    #expect(question.confirmed().widens)
                }
            }
        }
    }

    @Test("an audience nobody read: only Private goes without asking")
    func unknownStartWidensUnlessPrivate() {
        #expect(VisibilityChange.propose(.private, from: nil) != .unchanged)
        guard case .ready = VisibilityChange.propose(.private, from: nil) else {
            Issue.record("Private from an unknown audience asked")
            return
        }
        for to in [MemoVisibility.protected, .public] {
            guard case .ask = VisibilityChange.propose(to, from: nil) else {
                Issue.record("\(to) from an unknown audience went without asking")
                continue
            }
        }
    }

    @Test("the one line names what widening means")
    func wideningSentence() throws {
        guard case .ask(let toPublic) = VisibilityChange.propose(.public, from: .protected) else {
            Issue.record("Just us → Public did not ask")
            return
        }
        #expect(toPublic.sentence == "Everyone with the link can see it.")
        guard case .ask(let toUs) = VisibilityChange.propose(.protected, from: .private) else {
            Issue.record("Private → Just us did not ask")
            return
        }
        #expect(toUs.sentence == "Everyone with an account on this server can see it.")
    }

    // MARK: - the edit's PATCH

    @Test("a narrowing edit is one PATCH carrying the visibility, with no question asked")
    func narrowingEditSendsVisibility() async throws {
        let wire = server()
        guard case .ready(let change) = VisibilityChange.propose(.private, from: .public) else {
            Issue.record("Public → Private asked a question")
            return
        }
        let outcome = await TimelineStore().edit(
            uid: "a", content: "words", visibility: change,
            using: wire.client.handle, baseURL: Stub.baseURL
        )
        #expect(outcome.isSaved)
        #expect(wire.log.all.count == 1)
        #expect(wire.log.all.first?["visibility"] as? String == "PRIVATE")
        #expect(wire.log.all.first?["content"] as? String == "words")
    }

    @Test("an edit that leaves the audience alone does not name it in the PATCH")
    func unchangedVisibilityIsAbsent() async throws {
        let wire = server()
        #expect(VisibilityChange.propose(.public, from: .public) == .unchanged)
        let outcome = await TimelineStore().edit(
            uid: "a", content: "words", visibility: nil,
            using: wire.client.handle, baseURL: Stub.baseURL
        )
        #expect(outcome.isSaved)
        let body = try #require(wire.log.all.first)
        #expect(body["content"] as? String == "words", "control: the body was read")
        #expect(body["visibility"] == nil, "an untouched audience was restated: \(body)")
    }

    @Test("a confirmed widening edit is exactly one PATCH carrying the wider audience")
    func confirmedWideningEditSends() async throws {
        let wire = server()
        let store = TimelineStore()
        await store.refresh(using: wire.client.handle, baseURL: Stub.baseURL)
        guard case .ask(let question) = VisibilityChange.propose(.public, from: .private) else {
            Issue.record("Private → Public went without asking")
            return
        }
        let confirmed = question.confirmed()
        // The yes is final: proposing what it already says asks nothing a second time.
        #expect(VisibilityChange.propose(confirmed.to, from: confirmed.to) == .unchanged)
        let outcome = await store.edit(
            uid: "a", content: "words", visibility: confirmed,
            using: wire.client.handle, baseURL: Stub.baseURL
        )
        #expect(outcome.isSaved)
        #expect(wire.log.all.count == 1)
        #expect(wire.log.all.first?["visibility"] as? String == "PUBLIC")
    }

    // MARK: - the long press

    @Test("two quick taps on the same audience are ONE PATCH, answered to both (join)")
    func twoQuickTapsAreOnePatch() async throws {
        let release = LockedValue<Bool>(false)
        let wire = server(answer: { Stub.memo(uid: "a", visibility: "PRIVATE") }, release: release)
        let store = TimelineStore()
        await store.refresh(using: wire.client.handle, baseURL: Stub.baseURL)
        let change = VisibilityChange.cleared(.private, from: .public)
        let first = Task {
            await store.setVisibility(
                change, uid: "a", using: wire.client.handle, baseURL: Stub.baseURL)
        }
        while wire.log.all.isEmpty { await Task.yield() }
        let second = Task {
            await store.setVisibility(
                change, uid: "a", using: wire.client.handle, baseURL: Stub.baseURL)
        }
        try? await Task.sleep(for: .milliseconds(100))
        release.set(true)
        let firstAnswer = await first.value.isSaved
        let secondAnswer = await second.value.isSaved
        #expect(wire.log.all.count == 1, "one tap's change reached the server twice")
        #expect(firstAnswer && secondAnswer, "one request, answered to both")
        #expect(store.memos.first?.visibility == .private)
    }

    @Test("a narrowing queued behind another change is ASKED again once it has become a widening")
    func queuedNarrowingRevalidated() async throws {
        let release = LockedValue<Bool>(false)
        let wire = server(answer: { Stub.memo(uid: "a", visibility: "PRIVATE") }, release: release)
        let store = TimelineStore()
        await store.refresh(using: wire.client.handle, baseURL: Stub.baseURL)
        let toPrivate = VisibilityChange.cleared(.private, from: .public)
        // Proposed while the row still reads Public: a narrowing, so no question was asked.
        guard case .ready(let toUs) = VisibilityChange.propose(.protected, from: .public) else {
            Issue.record("Public → Just us asked")
            return
        }
        let first = Task {
            await store.setVisibility(
                toPrivate, uid: "a", using: wire.client.handle, baseURL: Stub.baseURL)
        }
        while wire.log.all.isEmpty { await Task.yield() }
        let second = Task {
            await store.setVisibility(
                toUs, uid: "a", using: wire.client.handle, baseURL: Stub.baseURL)
        }
        try? await Task.sleep(for: .milliseconds(100))
        release.set(true)
        #expect(await first.value.isSaved, "control: the narrowing landed")
        // Not refused: re-asked, as the widening it now is, from where the memo now stands.
        let outcome = await second.value
        guard case .ask(let question) = outcome else {
            Issue.record("Private → Just us was not re-asked: \(outcome)")
            return
        }
        #expect(question.from == .private && question.to == .protected)
        #expect(wire.log.all.map { $0["visibility"] as? String } == ["PRIVATE"])
        // The question's yes goes, once.
        #expect(
            await store.setVisibility(
                question.confirmed(), uid: "a", using: wire.client.handle, baseURL: Stub.baseURL
            ).isSaved)
        #expect(wire.log.all.map { $0["visibility"] as? String } == ["PRIVATE", "PROTECTED"])
    }

    @Test("an edit whose audience has become a widening while it queued is asked, not sent")
    func queuedEditReasked() async throws {
        let release = LockedValue<Bool>(false)
        let wire = server(answer: { Stub.memo(uid: "a", visibility: "PRIVATE") }, release: release)
        let store = TimelineStore()
        await store.refresh(using: wire.client.handle, baseURL: Stub.baseURL)
        guard case .ready(let toUs) = VisibilityChange.propose(.protected, from: .public) else {
            Issue.record("Public → Just us asked")
            return
        }
        let first = Task {
            await store.setVisibility(
                .cleared(.private, from: .public), uid: "a", using: wire.client.handle,
                baseURL: Stub.baseURL)
        }
        while wire.log.all.isEmpty { await Task.yield() }
        let edit = Task {
            await store.edit(
                uid: "a", content: "words", visibility: toUs,
                using: wire.client.handle, baseURL: Stub.baseURL)
        }
        try? await Task.sleep(for: .milliseconds(100))
        release.set(true)
        #expect(await first.value.isSaved, "control: the narrowing landed")
        let outcome = await edit.value
        #expect(outcome == .ask(VisibilityChange.Question(from: .private, to: .protected)))
        #expect(wire.log.all.count == 1, "the edit went out with an unconfirmed widening")
    }

    @Test("archived between two queued changes: the second is judged against what was sent")
    func absentRowJudgedAgainstLastSent() async throws {
        let release = LockedValue<Bool>(false)
        let log = PatchLog()
        // The server answers each PATCH with the memo as it then is: made Private, then archived.
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.page([Stub.memo(uid: "a", visibility: "PUBLIC")]))
            }
            log.record(Stub.object(try await Stub.bytes(body)))
            try await held(until: release)
            let archived = log.all.contains { $0["archived"] as? Bool == true }
            return Stub.json(
                Stub.memo(
                    uid: "a", visibility: "PRIVATE",
                    archivedAt: archived ? "2026-08-23T10:00:00Z" : nil))
        }
        let store = TimelineStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        guard case .ready(let toUs) = VisibilityChange.propose(.protected, from: .public) else {
            Issue.record("Public → Just us asked")
            return
        }
        let first = Task {
            await store.setVisibility(
                .cleared(.private, from: .public), uid: "a", using: client.handle,
                baseURL: Stub.baseURL)
        }
        while log.all.isEmpty { await Task.yield() }
        let archive = Task {
            await store.setArchived(true, uid: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        let second = Task {
            await store.setVisibility(
                toUs, uid: "a", using: client.handle, baseURL: Stub.baseURL)
        }
        try? await Task.sleep(for: .milliseconds(100))
        release.set(true)
        #expect(await first.value.isSaved, "control: the narrowing landed")
        #expect(await archive.value, "control: the archive landed")
        #expect(store.memos.isEmpty, "control: the archived row left the timeline")
        let outcome = await second.value
        #expect(!outcome.isSaved, "Private → Just us went out unconfirmed on an absent row")
        #expect(outcome == .ask(VisibilityChange.Question(from: .private, to: .protected)))
        #expect(
            log.all.compactMap { $0["visibility"] as? String } == ["PRIVATE"],
            "a second visibility reached the wire: \(log.all)")
    }

    @Test("a narrowing on a memo outside the loaded list goes as it is (absent is not unknown)")
    func absentRowNarrowingGoes() async throws {
        let wire = server(
            rows: [Stub.memo(uid: "b", visibility: "PUBLIC")],
            answer: { Stub.memo(uid: "a", visibility: "PROTECTED") })
        let store = TimelineStore()
        await store.refresh(using: wire.client.handle, baseURL: Stub.baseURL)
        guard case .ready(let toUs) = VisibilityChange.propose(.protected, from: .public) else {
            Issue.record("Public → Just us asked")
            return
        }
        let outcome = await store.setVisibility(
            toUs, uid: "a", using: wire.client.handle, baseURL: Stub.baseURL)
        #expect(outcome.isSaved, "an ordinary narrowing was refused for a memo not on screen")
        #expect(wire.log.all.map { $0["visibility"] as? String } == ["PROTECTED"])
    }

    @Test("an older edit's answer does not revert a newer long-press change (updated_at)")
    func staleEditAnswerDoesNotRevert() async throws {
        let wire = server(
            rows: [
                Stub.memo(
                    uid: "a", content: "before", visibility: "PUBLIC",
                    updatedAt: "2026-08-23T09:00:00Z")
            ],
            answer: {
                Stub.memo(
                    uid: "a", content: "after", visibility: "PRIVATE",
                    updatedAt: "2026-08-23T09:00:02Z")
            }
        )
        let store = TimelineStore()
        await store.refresh(using: wire.client.handle, baseURL: Stub.baseURL)
        let changed = await store.setVisibility(
            .cleared(.private, from: .public), uid: "a",
            using: wire.client.handle, baseURL: Stub.baseURL)
        #expect(changed.isSaved)
        #expect(store.memos.first?.visibility == .private, "control: the change landed")

        // The edit was written at :01, BEFORE the visibility change, and its answer arrives last.
        await store.apply(
            Self.memo(content: "after", visibility: .public, updatedAt: "2026-08-23T09:00:01Z"))
        #expect(store.memos.first?.visibility == .private, "a stale answer reverted the change")

        // Control: a NEWER answer is applied, so the guard is about age, not about refusing.
        await store.apply(
            Self.memo(content: "later", visibility: .protected, updatedAt: "2026-08-23T09:00:03Z"))
        #expect(store.memos.first?.visibility == .protected)
        #expect(store.memos.first?.content == "later")
    }

    private static func memo(content: String, visibility: MemoVisibility, updatedAt: String)
        -> Memo
    {
        Memo(
            uid: "a", owner: "fabian", mine: true, content: content, visibility: visibility,
            pinned: false,
            createdAt: ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z")!,
            updatedAt: ISO8601DateFormatter().date(from: updatedAt)!
        )
    }

    // MARK: - the batch

    @Test("a batch sends the confirmed change, visibility alone in each body")
    func batchSendsTheChange() async throws {
        let wire = server()
        guard case .ask(let question) = VisibilityChange.propose(.protected, from: nil) else {
            Issue.record("a batch to Just us went without asking")
            return
        }
        _ = await MemoActionStore(trips: nil).setVisibility(
            question.confirmed(), forMemos: ["m1", "m1"],
            using: wire.client.handle, baseURL: Stub.baseURL)
        #expect(wire.log.all.count == 1, "duplicates are one memo")
        #expect(wire.log.all.first.map { Array($0.keys) } == ["visibility"])
        #expect(wire.log.all.first?["visibility"] as? String == "PROTECTED")
    }
}
