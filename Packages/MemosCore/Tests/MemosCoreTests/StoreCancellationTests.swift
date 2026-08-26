import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

/// The failure a store must never report: the one it caused itself.
///
/// Every store here fences its reads, and fencing means cancelling. Cancelling a transfer is a
/// failure as far as URLSession is concerned — `NSURLErrorDomain -999`, wrapped in the generated
/// client's envelope — so a store that reports whatever it catches reports its own supersede back
/// to the person who caused it. That is MEMNG-180, reported from the app with
/// "Client encountered an error invoking list_memos … -999 cancelled" over a search that then
/// worked.
///
/// The lineage fence cannot cover it and is not asked to: `MemoSearch` cancels its in-flight work
/// BEFORE anything moves the store's lineage, so at the moment the `-999` lands the cancelled
/// request is still, by that test, the current one.
///
/// Everything below drives the REAL generated client over a scripted transport, so the error that
/// reaches a store is the error the stack really produces — envelope and all — rather than one the
/// test hand-built to match its own expectation.
@MainActor
@Suite("Store cancellation")
struct StoreCancellationTests {
    /// Keeps a scripted request open until the test lets it go, and reports when it has really
    /// started — a cancellation delivered before the request is out proves nothing.
    /// `nonisolated`, because the transport runs off the main actor.
    private nonisolated static func hold(
        entered: LockedValue<Bool>,
        until release: LockedValue<Bool>
    ) async throws {
        entered.set(true)
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// What the generated client actually throws when its transport fails this way — envelope,
    /// nesting and all. Classifying THAT is the whole job; classifying a bare `URLError` would
    /// skip the wrapper the app really meets.
    private nonisolated static func thrownByTheClient(_ error: any Error) async -> any Error {
        struct NeverThrew: Error {}
        let client = Stub.client { _, _, _ in throw error }
        do {
            _ = try await client.listTagsApiTagsGet(.init())
            return NeverThrew()
        } catch {
            return error
        }
    }

    // MARK: - the classification

    @Test("cancellation is recognised in every shape it arrives in")
    func everyShapeOfCancellationIsRecognised() async {
        #expect(StoreFailure.isCancellation(CancellationError()))
        #expect(StoreFailure.isCancellation(URLError(.cancelled)))
        #expect(
            StoreFailure.isCancellation(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            )
        )
        // Nested one level down, which is where CFNetwork routinely files the real cause.
        #expect(
            StoreFailure.isCancellation(
                NSError(
                    domain: "live.discomarder.memosng",
                    code: 1,
                    userInfo: [NSUnderlyingErrorKey: URLError(.cancelled) as NSError]
                )
            )
        )
        // And through the generated client's own envelope, which is how it actually arrives.
        #expect(StoreFailure.isCancellation(await Self.thrownByTheClient(URLError(.cancelled))))
        #expect(StoreFailure.isCancellation(await Self.thrownByTheClient(CancellationError())))
    }

    @Test("a genuine failure is not mistaken for a cancellation")
    func aRealFailureIsNotACancellation() async {
        // The control the whole fix stands on: if these were swallowed too, an offline phone would
        // simply go quiet.
        #expect(!StoreFailure.isCancellation(URLError(.notConnectedToInternet)))
        #expect(!StoreFailure.isCancellation(URLError(.timedOut)))
        #expect(!StoreFailure.isCancellation(APIError.server(status: 500)))
        #expect(
            !StoreFailure.isCancellation(
                await Self.thrownByTheClient(URLError(.notConnectedToInternet))
            )
        )
        #expect(StoreFailure.reportable(URLError(.cancelled)) == nil)
        #expect(StoreFailure.reportable(APIError.unauthorized) == .unauthorized)
        #expect(StoreFailure.reportable(URLError(.notConnectedToInternet)) != nil)
    }

    // MARK: - the stores

    /// The ticket's own sequence: a search is in flight, the sheet goes away (or a chip supersedes
    /// it), the store cancels — and the transport's `-999` must not become a sentence on screen.
    @Test("a cancelled search says nothing about the cancellation")
    func aCancelledSearchIsSilent() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let search = MemoSearch(
            client: Stub.client { _, _, _ in
                // What URLSession does to a transfer whose task is cancelled.
                do {
                    try await Self.hold(entered: entered, until: release)
                } catch {
                    throw URLError(.cancelled)
                }
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            },
            baseURL: Stub.baseURL
        )

        search.run(MemoQuery(tags: ["curated"]), showing: "#curated")
        while !entered.get() {
            await Task.yield()
        }
        search.cancelInFlight()
        release.set(true)
        await search.settled()

        #expect(
            search.results.lastError == nil,
            "the app reported its own cancellation: \(search.results.lastError ?? "")"
        )
        if case .failed(let why) = search.outcome {
            Issue.record("a cancelled search finished in a failed state: \(why)")
        }
    }

    /// The other direction, and the one that must never be lost: a search that really could not
    /// reach the server still says so.
    @Test("a search that genuinely fails still says so")
    func aFailedSearchStillReports() async {
        let search = MemoSearch(
            client: Stub.client { _, _, _ in throw URLError(.notConnectedToInternet) },
            baseURL: Stub.baseURL,
            coalescing: .milliseconds(1)
        )

        search.run(MemoQuery(tags: ["curated"]), showing: "#curated")
        await search.settled()

        #expect(search.results.lastError != nil, "an unreachable server said nothing")
        guard case .failed = search.outcome else {
            Issue.record("an unreachable server left the search in \(search.outcome)")
            return
        }
    }

    /// The whole class, one store at a time. Each of these fences or supersedes a fetch, so each
    /// of them can be handed its own cancellation — and all five now decide what to say about it
    /// in one place rather than in five that drift.
    @Test("no fenced store reports a cancellation, and every one still reports a real failure")
    func noFencedStoreReportsACancellation() async {
        for cancelled in [true, false] {
            let entered = LockedValue<Bool>(false)
            let release = LockedValue<Bool>(false)
            let client = Stub.client { _, _, _ in
                if cancelled {
                    // What URLSession does to a transfer whose task is cancelled.
                    do {
                        try await Self.hold(entered: entered, until: release)
                    } catch {
                        throw URLError(.cancelled)
                    }
                }
                throw URLError(.notConnectedToInternet)
            }

            let timeline = TimelineStore()
            let tags = TagStore()
            let heatmap = HeatmapStore()
            let library = MediaLibraryStore()
            let reads: [(String, @MainActor () async -> Void, @MainActor () -> String?)] = [
                (
                    "timeline",
                    { await timeline.refresh(using: client, baseURL: Stub.baseURL) },
                    { timeline.lastError }
                ),
                ("tags", { await tags.load(using: client) }, { tags.lastError }),
                ("heatmap", { await heatmap.load(using: client) }, { heatmap.lastError }),
                (
                    "library",
                    { await library.refresh(using: client, baseURL: Stub.baseURL) },
                    { library.lastError }
                ),
            ]

            for (name, read, reported) in reads {
                entered.set(false)
                release.set(false)
                let work = Task { await read() }
                if cancelled {
                    // A cancellation delivered before the request is out would prove nothing.
                    while !entered.get() {
                        await Task.yield()
                    }
                    work.cancel()
                    release.set(true)
                }
                await work.value

                if cancelled {
                    #expect(
                        reported() == nil,
                        "\(name) reported its own cancellation: \(reported() ?? "")"
                    )
                } else {
                    // The control, store by store: the same read against a server it cannot reach
                    // DOES say so, so the silence above is the cancellation and not a store that
                    // never speaks.
                    #expect(reported() != nil, "\(name) went quiet about an unreachable server")
                }
            }
        }
    }
}
