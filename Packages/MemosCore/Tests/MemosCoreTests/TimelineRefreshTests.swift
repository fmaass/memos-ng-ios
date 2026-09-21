import Foundation
import MemosAPI
import MemosCore
import Testing

/// Holds the FIRST list read at the transport until the case lets it through, and announces its
/// arrival — there is no "while a read is in flight" without a read that can be made to wait.
private actor RefreshGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// Called from inside the scripted transport: announces the request, then holds it.
    func enter() async {
        arrived = true
        let waiting = arrivals
        arrivals = []
        for waiter in waiting { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    /// Called from the case: returns once the request has reached the gate.
    func entered() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        released = true
        let waiting = parked
        parked = []
        for waiter in waiting { waiter.resume() }
    }
}

/// The reconciling re-read, and the projection both it and the live channel move.
///
/// The poll these tests grew up around is gone — `MediaChannel` consumes `GET /api/events` instead
/// (`MediaChannelTests`). What survives is the read it left behind: one memo, re-fetched once when
/// the channel starts, for the attachments no event will ever mention.
///
/// The requests are counted through a REAL generated client on a scripted transport, never a
/// stand-in for the store. Substituting the store would prove only that the test agrees with
/// itself.
@MainActor
@Suite("Timeline re-read")
struct TimelineRefreshTests {
    private nonisolated static let uid = "m1"

    /// The memo as the server would send it with one attachment at a given stage.
    ///
    /// `nonisolated static`, because it is called from inside the scripted transport, which the
    /// client runs off the main actor.
    private nonisolated static func memo(_ status: String) -> String {
        Stub.memo(uid: uid, attachments: [Stub.attachment(uid: "a1", status: status)])
    }

    /// A store with one waiting memo in it, loaded the way the app loads one.
    private func loaded(_ client: any APIProtocol) async -> TimelineStore {
        let store = TimelineStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        return store
    }

    // MARK: - a refresh asked for while one is in flight

    /// A refresh refused because the same list was already being read must not simply be lost.
    ///
    /// The read in flight left BEFORE the refusal, so its answer cannot carry whatever made
    /// somebody ask again — a route regain arriving mid-read is exactly that, and the list it
    /// leaves on the screen is the one from before the outage. Refused and remembered: one more
    /// read after the one in flight, however many were refused, because they all ask the same
    /// question.
    @Test("a refresh refused while the list is being read is taken once that read answers")
    func aRefusedRefreshIsTakenOnceAfterwards() async {
        let gate = RefreshGate()
        let pages = LockedValue<Int>(0)
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                let ordinal = pages.get() + 1
                pages.set(ordinal)
                if ordinal == 1 { await gate.enter() }
                return Stub.json(Stub.page([Stub.memo(uid: Self.uid)]))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = TimelineStore()
        let first = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        await gate.entered()

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(pages.get() == 1, "a second read went out beside the one already in flight")

        await gate.release()
        await first.value
        #expect(await Self.settles(until: { pages.get() >= 2 }), "the refused refresh was dropped")
        // And only one, for two refusals: they asked the same question of the same list.
        _ = await Self.settles(until: { pages.get() > 2 })
        #expect(pages.get() == 2, "two refusals were answered with two reads rather than one")
    }

    /// Gives the store's own tail its turns, and gives up rather than hanging.
    private static func settles(tries: Int = 60, until ready: () -> Bool) async -> Bool {
        for _ in 0..<tries {
            if ready() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return ready()
    }

    // MARK: - the re-read itself

    /// The refreshed attachment data has to land in the card that is already on screen, through
    /// the same path an edit takes — not as a new row, and not by reordering the timeline.
    @Test("a re-read replaces the memo in place, leaving the list alone")
    func refreshMemoAppliesInPlace() async {
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(
                    Stub.page([
                        Stub.memo(uid: "older", createdAt: "2026-08-23T08:00:00Z"),
                        Self.memo("pending"),
                    ])
                )
            case "get_memo_api_memos__uid__get":
                return Stub.json(Self.memo("ready"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = TimelineStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["older", Self.uid])

        let refreshed = await store.refreshMemo(
            uid: Self.uid, using: client.handle, baseURL: Stub.baseURL
        )

        #expect(refreshed)
        #expect(store.memos.map(\.uid) == ["older", Self.uid], "the re-read reordered the list")
        #expect(store.memos.count == 2, "the re-read added a row instead of replacing one")
        #expect(store.memos[1].attachments.first?.readiness == .ready)
    }

    /// A background re-read is not the timeline's error banner. It runs behind a screen nobody
    /// asked to refresh, and a blip on it must not paint a notice over a timeline that works.
    @Test("a re-read that failed says nothing on the timeline")
    func backgroundFailureIsSilent() async {
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Self.memo("pending")]))
            default:
                return Stub.empty(.internalServerError)
            }
        }
        let store = await loaded(client)
        #expect(store.lastError == nil)

        let refreshed = await store.refreshMemo(
            uid: Self.uid, using: client.handle, baseURL: Stub.baseURL
        )

        #expect(!refreshed)
        #expect(store.lastError == nil, "a background re-read painted an error on the timeline")
        // The control: a foreground refresh through the same failing transport DOES report, so
        // the silence above is this method's own decision and not a broken stub.
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.lastError == nil)
    }

    // MARK: - MEMNG-191: a memo this list has never loaded

    /// The read a jump from the media library depends on.
    ///
    /// `refreshMemo` cannot serve it and the difference is the whole point: it goes through
    /// `apply`, which drops a memo the loaded list does not already contain. A photograph a few
    /// screens into the library routinely belongs to a memo a hundred cursor pages down, so the
    /// value has to come BACK — that is what the detail screen opens with.
    @Test("a memo outside the loaded window is fetched and handed back, list untouched")
    func fetchMemoReturnsOneTheListNeverLoaded() async throws {
        let reads = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Stub.memo(uid: "loaded")]))
            case "get_memo_api_memos__uid__get":
                reads.increment()
                return Stub.json(Stub.memo(uid: "far-away", content: "down the list"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = await loaded(client)
        #expect(store.memos.map(\.uid) == ["loaded"])

        // The control first: the method this one exists beside genuinely drops it.
        let applied = await store.refreshMemo(
            uid: "far-away", using: client.handle, baseURL: Stub.baseURL
        )
        #expect(applied, "control: the server did answer")
        #expect(store.memos.map(\.uid) == ["loaded"], "control: apply kept it out of the list")

        let fetched = try #require(
            await store.fetchMemo(uid: "far-away", using: client.handle, baseURL: Stub.baseURL)
        )

        #expect(fetched.uid == "far-away")
        #expect(fetched.content == "down the list")
        #expect(reads.count == 2, "the memo was not read from the server")
        #expect(store.memos.map(\.uid) == ["loaded"], "the fetch inserted a row into the timeline")
    }

    @Test("a memo the list DOES hold comes back as the server's copy, applied in place")
    func fetchMemoAppliesWhenTheListHoldsIt() async throws {
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Stub.memo(uid: "m1", content: "stale")]))
            case "get_memo_api_memos__uid__get":
                return Stub.json(Stub.memo(uid: "m1", content: "fresh"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = await loaded(client)
        #expect(store.memos.first?.content == "stale")

        let fetched = try #require(
            await store.fetchMemo(uid: "m1", using: client.handle, baseURL: Stub.baseURL)
        )

        #expect(fetched.content == "fresh")
        #expect(store.memos.map(\.uid) == ["m1"], "the fetch added a second copy")
        #expect(store.memos.first?.content == "fresh", "the loaded copy was left stale")
    }

    // MARK: - MEMNG-191: the jump has to leave the store OWNING the memo

    /// A UTC day calendar, so which day the memo falls on is a fact of the test rather than of the
    /// machine's time zone.
    private nonisolated static var utcDays: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// The whole point of the jump, and the thing fetching alone cannot buy: after it, the memo is
    /// IN the loaded list, so an edit made on the screen it opens lands here instead of being
    /// dropped by `apply`.
    @Test("a jump anchors the list at the memo's day, and an edit afterwards lands in the store")
    func jumpAnchorsSoTheStoreOwnsTheMemo() async throws {
        let far = "far-away"
        let client = Stub.client { request, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                // The plain timeline does not reach back this far; the ANCHORED one does.
                guard (request.path ?? "").contains("created_before") else {
                    return Stub.json(Stub.page([Stub.memo(uid: "recent")]))
                }
                return Stub.json(Stub.page([Stub.memo(uid: far, content: "written then")]))
            case "get_memo_api_memos__uid__get":
                return Stub.json(Stub.memo(uid: far, content: "written then"))
            case "patch_memo_api_memos__uid__patch":
                return Stub.json(Stub.memo(uid: far, content: "edited on the detail screen"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = await loaded(client)
        #expect(store.memos.map(\.uid) == ["recent"], "control: the memo starts outside the window")

        let outcome = await store.jump(
            to: far, calendar: Self.utcDays, using: client.handle, baseURL: Stub.baseURL
        )

        guard case .ready(let opened) = outcome else {
            Issue.record("the jump did not end ready")
            return
        }
        #expect(opened.uid == far)
        #expect(store.memos.contains { $0.uid == far }, "the jump left the memo outside the window")
        #expect(store.query.anchor != nil, "the list was never anchored")

        // The blocker this exists for: an edit through the store must reach the loaded row.
        let edited = await store.edit(
            uid: far,
            content: "edited on the detail screen",
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved
        #expect(edited)
        #expect(
            store.memos.first { $0.uid == far }?.content == "edited on the detail screen",
            "the edit was discarded — the store never owned the memo"
        )
    }

    /// Deleted while the jump was in flight: anchoring lands on a day that no longer holds it.
    @Test("a memo missing from the anchored window is unavailable rather than pushed")
    func jumpRefusesWhenTheAnchoredWindowLacksIt() async {
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Stub.memo(uid: "someone-else")]))
            case "get_memo_api_memos__uid__get":
                return Stub.json(Stub.memo(uid: "gone"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = await loaded(client)

        let outcome = await store.jump(
            to: "gone", calendar: Self.utcDays, using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .unavailable)
        #expect(!store.memos.contains { $0.uid == "gone" })
    }

    @Test("a memo already on screen is ready without moving the list")
    func jumpToALoadedMemoLeavesTheListAlone() async {
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Stub.memo(uid: "here")]))
            case "get_memo_api_memos__uid__get":
                return Stub.json(Stub.memo(uid: "here", content: "fresh"))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = await loaded(client)

        let outcome = await store.jump(
            to: "here", calendar: Self.utcDays, using: client.handle, baseURL: Stub.baseURL
        )

        if case .unavailable = outcome { Issue.record("a loaded memo came back unavailable") }
        #expect(store.query.anchor == nil, "a memo already on screen moved the list anyway")
        #expect(store.memos.first?.content == "fresh")
    }

    @Test("a memo that cannot be read is a nil rather than a navigation")
    func fetchMemoFailureIsNil() async {
        let client = Stub.client { _, _, operation in
            switch operation {
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Stub.memo(uid: "loaded")]))
            default:
                return Stub.empty(.internalServerError)
            }
        }
        let store = await loaded(client)

        let fetched = await store.fetchMemo(
            uid: "gone", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(fetched == nil)
        #expect(store.lastError == nil, "a jump that failed painted an error on the timeline")
    }

    // MARK: - a read the server never answered is not a memo that is gone

    private nonisolated static let whoamiOperation = "whoami_api_auth_user_get"

    /// A REAL session over a scripted transport, signed in the way the app signs in.
    ///
    /// Real, because what the jump has to reach is the session's own notice, and a stand-in for
    /// the session would prove only that the test agrees with itself. The sleeper throws instead
    /// of waiting: the retry ladder a failure starts would otherwise re-verify the session
    /// underneath the witness.
    private func signedIn(handler: @escaping StubTransport.Handler) async -> SessionStore {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            sleeper: { _ in throw CancellationError() }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    /// A photograph's "Show Memo" over a network that dropped the read. The memo is there; the
    /// request never arrived — so the reader must not be told it is gone, and the one place this
    /// app says the server cannot be reached has to hear about it.
    @Test("a memo read that never reached the server is unreadable, and the session is told")
    func jumpReportsAReadThatNeverReachedTheServer() async throws {
        let session = await signedIn { _, _, operation in
            switch operation {
            case Self.whoamiOperation:
                return Stub.json(Stub.user)
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Stub.memo(uid: "loaded")]))
            default:
                throw URLError(.timedOut)
            }
        }
        let store = TimelineStore()
        store.reports(to: session)
        let handle = try #require(session.activeHandle)
        await store.refresh(using: handle, baseURL: Stub.baseURL)
        #expect(session.verification == .verified, "control: the list read did reach the server")

        let outcome = await store.jump(
            to: "far-away", calendar: Self.utcDays, using: handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .unreadable, "a dropped read was reported as a memo that is gone")
        guard case .unverified = session.verification else {
            Issue.record("the session was never told: verification is \(session.verification)")
            return
        }
        #expect(session.state.user != nil, "the session stands: this is not a refusal")
    }

    /// The other half of the sentence: the server ANSWERED, and what it said was that there is no
    /// such memo. That one really is gone, and it says nothing about reaching the server.
    @Test("a memo the server says it does not have is unavailable, and the session hears nothing")
    func jumpToAMemoTheServerDoesNotHave() async throws {
        let session = await signedIn { _, _, operation in
            switch operation {
            case Self.whoamiOperation:
                return Stub.json(Stub.user)
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Stub.memo(uid: "loaded")]))
            default:
                return Stub.empty(.notFound)
            }
        }
        let store = TimelineStore()
        store.reports(to: session)
        let handle = try #require(session.activeHandle)
        await store.refresh(using: handle, baseURL: Stub.baseURL)

        let outcome = await store.jump(
            to: "gone", calendar: Self.utcDays, using: handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .unavailable)
        #expect(
            session.verification == .verified,
            "a 404 is the server answering, and says nothing about reaching it"
        )
    }

    /// The third answer the server can give: an error of its own. The memo may well still be
    /// there, so this is not "no longer here" either — and the server plainly WAS reached, so the
    /// one surface that says it cannot be must hear nothing about it.
    @Test("a memo the server fails to read is unreadable, and the session hears nothing")
    func jumpToAMemoTheServerFailsToRead() async throws {
        let session = await signedIn { _, _, operation in
            switch operation {
            case Self.whoamiOperation:
                return Stub.json(Stub.user)
            case "list_memos_api_memos_get":
                return Stub.json(Stub.page([Stub.memo(uid: "loaded")]))
            default:
                return Stub.empty(.internalServerError)
            }
        }
        let store = TimelineStore()
        store.reports(to: session)
        let handle = try #require(session.activeHandle)
        await store.refresh(using: handle, baseURL: Stub.baseURL)

        let outcome = await store.jump(
            to: "broken", calendar: Self.utcDays, using: handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .unreadable, "a 500 was reported as a memo that is gone")
        #expect(
            session.verification == .verified,
            "a 500 is the server answering, and says nothing about reaching it"
        )
    }
}

/// The three-way projection, on the model, where the view, the re-read and the live channel
/// all read it from.
@Suite("Attachment readiness")
struct AttachmentReadinessTests {
    private func attachment(_ status: AttachmentStatus) -> MemoAttachment {
        MemoAttachment(uid: "a1", mime: "image/jpeg", status: status)
    }

    private func memo(_ statuses: [AttachmentStatus]) -> Memo {
        Memo(
            uid: "m1",
            owner: "fabian",
            mine: true,
            content: "hello",
            visibility: .private,
            pinned: false,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            attachments: statuses.enumerated().map {
                MemoAttachment(uid: "a\($0.offset)", mime: "image/jpeg", status: $0.element)
            }
        )
    }

    /// A case per status, and the three answers are genuinely three. `uploading` is grouped with
    /// the server-side stages on purpose: to a reader, a file still on its way and a file the
    /// worker has not reached yet are the same thing — something is coming, nothing is broken.
    @Test("every status projects to one of exactly three treatments")
    func everyStatusIsProjected() {
        #expect(attachment(.ready).readiness == .ready)
        #expect(attachment(.pending).readiness == .waiting)
        #expect(attachment(.processing).readiness == .waiting)
        #expect(attachment(.uploading).readiness == .waiting)
        #expect(attachment(.failed).readiness == .failed)
        #expect(Set([AttachmentReadiness.ready, .waiting, .failed]).count == 3)
        // The one that matters: pending is NOT failed. That equivalence is what put a row of
        // warning triangles on the first real post from the phone.
        #expect(attachment(.pending).readiness != attachment(.failed).readiness)
    }

    @Test("a memo is waiting while any one of its attachments is")
    func memoWaitsForAnyAttachment() {
        #expect(!memo([]).isAwaitingTiers)
        #expect(!memo([.ready, .ready]).isAwaitingTiers)
        #expect(memo([.ready, .pending]).isAwaitingTiers)
        #expect(memo([.processing]).isAwaitingTiers)
        #expect(memo([.uploading, .ready]).isAwaitingTiers)
        // A failed attachment is not something to wait for: nothing more is coming for it.
        #expect(!memo([.ready, .failed]).isAwaitingTiers)
        #expect(!memo([.failed]).isAwaitingTiers)
    }
}
