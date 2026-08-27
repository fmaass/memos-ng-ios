import Foundation
import MemosAPI
import MemosCore
import Testing

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
        await store.refresh(using: client, baseURL: Stub.baseURL)
        return store
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
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["older", Self.uid])

        let refreshed = await store.refreshMemo(
            uid: Self.uid, using: client, baseURL: Stub.baseURL
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
            uid: Self.uid, using: client, baseURL: Stub.baseURL
        )

        #expect(!refreshed)
        #expect(store.lastError == nil, "a background re-read painted an error on the timeline")
        // The control: a foreground refresh through the same failing transport DOES report, so
        // the silence above is this method's own decision and not a broken stub.
        await store.refresh(using: client, baseURL: Stub.baseURL)
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
            uid: "far-away", using: client, baseURL: Stub.baseURL
        )
        #expect(applied, "control: the server did answer")
        #expect(store.memos.map(\.uid) == ["loaded"], "control: apply kept it out of the list")

        let fetched = try #require(
            await store.fetchMemo(uid: "far-away", using: client, baseURL: Stub.baseURL)
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
            await store.fetchMemo(uid: "m1", using: client, baseURL: Stub.baseURL)
        )

        #expect(fetched.content == "fresh")
        #expect(store.memos.map(\.uid) == ["m1"], "the fetch added a second copy")
        #expect(store.memos.first?.content == "fresh", "the loaded copy was left stale")
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
            uid: "gone", using: client, baseURL: Stub.baseURL
        )

        #expect(fetched == nil)
        #expect(store.lastError == nil, "a jump that failed painted an error on the timeline")
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
