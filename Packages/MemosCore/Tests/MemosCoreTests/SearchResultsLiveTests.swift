import Foundation
import MemosAPI
@testable import MemosCore
import Testing

/// Live tiers on the screen a search pushes.
///
/// The results are a list of their OWN — a second store beside the timeline's, deliberately, so a
/// search does not spend the home list's scroll position to show a result and spend it again to
/// take the filter off. The device has exactly ONE live connection
/// (`MediaEventClient.device().stream()`), and it used to patch exactly one list, so a photo that
/// finished while somebody was reading their results stayed under the waiting treatment until they
/// left the screen and came back to it.
///
/// Two questions decide whether a second list may share one connection, and both are asked here:
/// what reaches the results list, and what must NOT — an attachment uid names a memo the results
/// have very often never loaded, and a list that reacted to one would be re-reading the timeline's
/// memos on the search's behalf.
///
/// Nothing here waits on a clock or a connection: the stream is handed over as values, and every
/// request a pass makes is counted through a REAL generated client on a scripted transport.
@MainActor
@Suite("Search results live")
struct SearchResultsLiveTests {
    /// The memo the search found and the screen is showing.
    private nonisolated static let found = "m-found"
    /// A second result, finished long before the search ran — nothing is owed for it.
    private nonisolated static let settled = "m-settled"
    /// A memo only the HOME timeline holds. Most of this suite is about ITS event.
    private nonisolated static let home = "m-home"
    /// Attachment uids from the captured server frames (`SSEFixture`), so the events applied here
    /// are ones a real memos-ng wrote rather than ones invented to match the assertion.
    private nonisolated static let foundAttachment = "a1b2c3d4"
    private nonisolated static let homeAttachment = "e5f6a7b8"

    private nonisolated static func memo(
        _ uid: String,
        attachment: String,
        _ status: String
    ) -> String {
        Stub.memo(uid: uid, attachments: [Stub.attachment(uid: attachment, status: status)])
    }

    /// Keeps a scripted request open until the test lets it go. `nonisolated`, because the
    /// transport runs off the main actor.
    private nonisolated static func hold(until release: LockedValue<Bool>) async throws {
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// The worker's finish on the attachment the RESULTS screen is showing, carrying the layout it
    /// wrote, and the same for the one only the timeline holds.
    private nonisolated static var foundReady: MediaEvent { SSEFixture.liveEvents[2] }
    private nonisolated static var homeReady: MediaEvent { SSEFixture.liveEvents[4] }

    // MARK: - the two lists, as the app has them while the results screen is up

    private struct Loaded {
        let timeline: TimelineStore
        let search: MemoSearch
        let client: any APIProtocol
        /// The paths every re-read asked for, so "only what is waiting" is a claim about requests.
        let asked: Box<[String]>
    }

    /// A home timeline and a search, each read through the same scripted server.
    ///
    /// The search's request is the one carrying `q=`, which is how the script tells the two lists
    /// apart — the same fact the server uses.
    private func loaded(
        home homeStatus: String,
        found foundStatus: String,
        reReadsAs: String = "ready"
    ) async -> Loaded {
        let asked = Box<[String]>([])
        let client = Stub.client { request, _, operation in
            let path = request.path ?? ""
            switch operation {
            case "list_memos_api_memos_get":
                let row =
                    path.contains("q=")
                    ? Self.memo(Self.found, attachment: Self.foundAttachment, foundStatus)
                    : Self.memo(Self.home, attachment: Self.homeAttachment, homeStatus)
                return Stub.json(Stub.page([row]))
            case "get_memo_api_memos__uid__get":
                asked.value.append(path)
                let isFound = path.contains(Self.found)
                return Stub.json(
                    Self.memo(
                        isFound ? Self.found : Self.home,
                        attachment: isFound ? Self.foundAttachment : Self.homeAttachment,
                        reReadsAs
                    )
                )
            default:
                return Stub.empty(.notFound)
            }
        }
        let timeline = TimelineStore()
        await timeline.refresh(using: client, baseURL: Stub.baseURL)
        let search = MemoSearch(
            client: client,
            baseURL: Stub.baseURL,
            coalescing: .milliseconds(1)
        )
        search.typed("travel")
        await search.settled()
        return Loaded(timeline: timeline, search: search, client: client, asked: asked)
    }

    /// The channel, running into the timeline with the results list beside it — the wiring the
    /// app has while that screen is pushed.
    private func consume(_ items: [MediaEventStreamItem], _ fixture: Loaded) async {
        await MediaChannel.consume(
            channel(items),
            into: fixture.timeline,
            alongside: { [fixture.search.results] },
            using: fixture.client,
            baseURL: Stub.baseURL,
            identity: MediaIdentity()
        )
    }

    /// A finite channel of exactly these items, already buffered — an event really does sit in the
    /// stream's buffer between arriving and being consumed.
    private func channel(_ items: [MediaEventStreamItem]) -> AsyncStream<MediaEventStreamItem> {
        AsyncStream { continuation in
            for item in items { continuation.yield(item) }
            continuation.finish()
        }
    }

    private func envelope(_ event: MediaEvent) -> MediaEventEnvelope {
        MediaEventEnvelope(event: event, generation: 0)
    }

    // MARK: - appearing

    /// The screen is pushed while the search it is showing may still be OUT.
    ///
    /// The hand-off close leaves the answer in flight on purpose — cancelling it left the reader on
    /// a spinner over nothing whenever the network was slower than the dismissal animation
    /// (MEMNG-177) — so arriving before the rows do is the ordinary case, not a corner one. A
    /// reconciling pass taken at that moment looks at a list nothing has been read into, finds
    /// nothing awaiting tiers, and re-reads nothing; the rows land a moment later still showing the
    /// waiting treatment, and no event will ever mention them, because an attachment that finished
    /// before this connection's snapshot is in no snapshot to drop out of
    /// (`MediaChannel.uidsToReconcile`).
    ///
    /// So the pass waits for the search first, and then re-reads ONLY what is still waiting: the
    /// result that was finished when it was read is not asked for at all.
    @Test("appearing reconciles only attachments still awaiting tiers")
    func appearingReconcilesOnlyWhatIsWaiting() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let asked = Box<[String]>([])
        let client = Stub.client { request, _, operation in
            let path = request.path ?? ""
            switch operation {
            case "list_memos_api_memos_get":
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.json(
                    Stub.page([
                        Self.memo(Self.settled, attachment: "a-settled", "ready"),
                        Self.memo(Self.found, attachment: Self.foundAttachment, "pending"),
                    ])
                )
            case "get_memo_api_memos__uid__get":
                asked.value.append(path)
                return Stub.json(
                    Self.memo(Self.found, attachment: Self.foundAttachment, "ready")
                )
            default:
                return Stub.empty(.notFound)
            }
        }
        let search = MemoSearch(
            client: client,
            baseURL: Stub.baseURL,
            coalescing: .milliseconds(1)
        )
        search.typed("travel")
        while !entered.get() {
            await Task.yield()
        }

        let appearing = Task { await search.resultsAppeared() }
        // Let the pass reach whatever it waits on before the answer lands. That ordering IS the
        // question: park it here and a pass that does not wait has already finished, over nothing.
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(search.results.memos.isEmpty, "the search answered before the screen appeared")

        release.set(true)
        await appearing.value

        #expect(
            asked.value.count == 1,
            "the appearing pass asked \(asked.value.count) times, not once"
        )
        #expect(
            asked.value.first?.contains(Self.found) == true,
            "the appearing pass re-read \(asked.value.first ?? "nothing")"
        )
        let reconciled = search.results.memos.first { $0.uid == Self.found }
        #expect(reconciled?.isAwaitingTiers == false, "the result stayed under a waiting tile")
        #expect(search.results.memos.first { $0.uid == Self.settled }?.isAwaitingTiers == false)

        // Coming back to a screen with nothing waiting costs nothing at all, which is what makes
        // the pass safe to take at every appearance.
        await search.resultsAppeared()
        #expect(asked.value.count == 1, "a second appearance re-read a list with nothing waiting")
    }

    // MARK: - the live channel, with two lists on it

    /// One connection, two lists — and an event belongs to whichever of them holds the attachment.
    ///
    /// The negative half is the one with teeth: the results are a search, so the timeline's memos
    /// are mostly memos they have never loaded, and a list that reacted to their events would be
    /// re-reading them on the search's behalf and re-rendering itself once every second and a half
    /// during somebody else's transcode.
    ///
    /// The positive control is in the same run and the same fixture, because "nothing changed" is
    /// what a channel that reaches this list not at all would also say.
    @Test("a media event for a memo outside the list changes nothing")
    func anEventForAMemoOutsideTheResultsChangesNothing() async {
        let fixture = await loaded(home: "pending", found: "pending")
        #expect(fixture.search.results.memos.map(\.uid) == [Self.found])
        #expect(fixture.timeline.memos.map(\.uid) == [Self.home])
        let before = fixture.search.results.memos

        await consume([.event(envelope(Self.homeReady))], fixture)

        #expect(
            fixture.search.results.memos == before,
            "an event for a memo the results do not hold moved the results list"
        )
        #expect(
            fixture.asked.value.isEmpty,
            "the results list was re-read for a memo it does not hold: \(fixture.asked.value)"
        )
        // Control: the event was live and really did reach the channel — the list that DOES hold
        // that attachment moved on it.
        #expect(fixture.timeline.memos.first?.attachments.first?.readiness == .ready)

        // And the other direction, on the same two lists: the event this screen is waiting for
        // flips its tile where it sits, which is the whole of what the results screen was missing.
        await consume([.event(envelope(Self.foundReady))], fixture)
        let tile = fixture.search.results.memos.first?.attachments.first
        #expect(tile?.readiness == .ready, "the results screen sat on a tile the server had ready")
        // Carrying the layout the worker wrote, so the tile is laid out at the right ratio rather
        // than at the placeholder square it was read with.
        #expect(tile?.width == 4032)
        #expect(tile?.height == 3024)
        #expect(tile?.blurhash == "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
        #expect(
            fixture.asked.value.isEmpty,
            "a URL already in hand was re-read for its own event: \(fixture.asked.value)"
        )
    }

    /// The one thing the stream cannot say, said for the results list too.
    ///
    /// Each connection watches only what its OWN snapshot held, so an attachment that was already
    /// finished when the connection opened is mentioned by nothing — and the results list meets
    /// that case constantly, because it is read AFTER the connection opened and pages further rows
    /// in as somebody scrolls. The pass at every open is what covers those rows; the appearing pass
    /// covers only the ones on screen when it ran.
    @Test("every connection open reconciles the results list too")
    func everyOpenReconcilesTheResultsList() async {
        let fixture = await loaded(home: "ready", found: "pending")

        await consume([.state(.connecting(attempt: 1)), .state(.open)], fixture)

        #expect(
            fixture.asked.value.count == 1,
            "the open re-read \(fixture.asked.value.count) memos, not one"
        )
        #expect(
            fixture.asked.value.first?.contains(Self.found) == true,
            "the open re-read \(fixture.asked.value.first ?? "nothing")"
        )
        #expect(
            fixture.search.results.memos.first?.isAwaitingTiers == false,
            "the result the open found finished stayed under a waiting tile"
        )
        // The timeline had nothing waiting, so the open cost it nothing — the count above is the
        // whole of what this connection asked for.
        #expect(fixture.timeline.memos.first?.isAwaitingTiers == false)
    }
}
