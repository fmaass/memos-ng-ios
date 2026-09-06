import Foundation
import MemosAPI
import MemosCore
import Testing

/// What the search sheet's filters ask the server for.
///
/// Every claim here is read back off a request that really left the app: the REAL generated client
/// over a scripted transport, the same discipline the rest of this bundle keeps. A filter is only
/// a filter once it is a query parameter, and a stand-in for the client would prove nothing about
/// which parameters were built.
///
/// The filters are a value of their own rather than fields on `MemoQuery` because one of them is
/// not a field at all. The server takes TWO archive flags and decides between them itself —
/// `archived_only` wins, and `include_archived` is consulted only when it is off
/// (memos-ng `app/services/memos.py:305-307`) — so `MemoQuery` keeps both, faithfully. What a
/// person picks is ONE thing, and `MemoArchiveScope` is where that is true.
@MainActor
@Suite("Filters")
struct SearchFiltersTests {
    /// Three tags, three different counts — one of them nothing at all, which is the count that
    /// decides whether a tag is a control.
    private nonisolated static let tagList =
        #"[{"name":"travel","count":9},{"name":"food","count":2},{"name":"stale","count":0}]"#

    private static func search(handler: @escaping StubTransport.Handler) -> MemoSearch {
        MemoSearch(
            handle: Stub.client(handler: handler).handle, baseURL: Stub.baseURL)
    }

    /// The query parameters of one request, as the server would read them: repeated names kept in
    /// order, percent-encoding undone.
    private static func sent(_ path: String) -> [String: [String]] {
        var parsed: [String: [String]] = [:]
        for item in URLComponents(string: path)?.queryItems ?? [] {
            parsed[item.name, default: []].append(item.value ?? "")
        }
        return parsed
    }

    // MARK: - the tags a person picks from

    /// The chips are not a guess at what the household writes about: they are what the server
    /// says, with the number under each one, and the count is what orders and gates the row.
    ///
    /// The count travelling intact is the half worth pinning. A name that arrived without its
    /// count would leave every tag looking equally used, and a zero count is what makes a tag
    /// refusable — `TagChipsPresentation` will not build a chip for a tag nothing is filed under.
    @Test("tags come from /api/tags with counts")
    func tagsComeFromTheServerWithTheirCounts() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(Self.tagList)
        }
        let store = TagStore()

        await store.load(using: client.handle)

        // Control: this is the tags endpoint, built by the generated client rather than by a
        // string in the test.
        #expect(paths.get() == ["/api/tags"])
        #expect(
            store.tags == [
                MemoTag(name: "travel", count: 9),
                MemoTag(name: "food", count: 2),
                MemoTag(name: "stale", count: 0),
            ],
            "a tag arrived without the count that came with it"
        )
        // The counts really are per-tag, not one number repeated: the three differ, and the
        // largest belongs to the tag the server said it belonged to.
        let counts: [Int] = store.tags.map(\.count)
        let mostUsed: MemoTag? = store.tags.max(by: { $0.count < $1.count })
        #expect(counts == [9, 2, 0])
        #expect(mostUsed?.name == "travel")

        // And a name is a name: what a filter sends is the bare tag, never the "#" a person reads.
        let filters = SearchFilters.empty.toggling("travel")
        #expect(filters.tags == ["travel"])
        #expect(filters.query().tags == ["travel"], "the hash leaked into what goes on the wire")
    }

    // MARK: - two tags

    /// Two tags are an AND, not a replacement. The server ANDs one `EXISTS` per `tag`
    /// (memos-ng `app/services/memos.py:322-331`), so both names have to be on the ONE request:
    /// a second tag that replaced the first would silently widen the list back out to everything
    /// filed under the newer one.
    @Test("two tags AND")
    func twoTagsGoOutTogetherOnOneRequest() async {
        let paths = LockedValue<[String]>([])
        let search = Self.search { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }

        search.apply(SearchFilters.empty.toggling("travel").toggling("food"))
        await search.settled()

        #expect(search.filters.tags == ["travel", "food"], "the second tag replaced the first")
        let requests = paths.get().map { Self.sent($0) }
        #expect(requests.count == 1, "two tags went out as \(requests.count) requests")
        #expect(requests.first?["tag"] == ["travel", "food"], "a tag was dropped on the wire")
        #expect(requests.first?["q"] == nil, "a tag went out as a text search")
        #expect(search.outcome == .matched)

        // Control, one: a single tag really does send a single `tag`, so the pair above is two
        // tags composing rather than a parameter that is always repeated.
        let onePath = LockedValue<[String]>([])
        let one = Self.search { request, _, _ in
            onePath.set(onePath.get() + [request.path ?? ""])
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        one.apply(SearchFilters.empty.toggling("travel"))
        await one.settled()
        let oneRequests: [[String: [String]]] = onePath.get().map({ Self.sent($0) })
        #expect(oneRequests.first?["tag"] == ["travel"])

        // Control, two: the same gesture on a tag already chosen takes it OFF again — which is
        // what makes the row a selection rather than a one-way accumulator.
        #expect(SearchFilters.empty.toggling("travel").toggling("travel") == .empty)
        #expect(
            SearchFilters.empty.toggling("travel").toggling("food").toggling("travel").tags
                == ["food"],
            "removing the first tag disturbed the second"
        )
        // And a tag chosen twice is one tag: a repeat must not send `tag=travel&tag=travel`,
        // which asks the server for memos filed under travel AND travel.
        #expect(SearchFilters(tags: ["travel", "travel", "food"]).tags == ["travel", "food"])
    }

    // MARK: - the archives

    /// The two archive flags are ONE choice, and this is where that is true.
    ///
    /// `archived_only=true&include_archived=true` is not an error the server reports — it simply
    /// picks (`archived_only` wins, `app/services/memos.py:305-307`), so a surface that could send
    /// both would be a surface whose "include the archived ones" toggle silently did nothing on
    /// some settings and not others. Every scope there is, is driven all the way to a real
    /// request here, so a case added later cannot skip this.
    @Test("archived-only and include-archived cannot both reach one request")
    func theTwoArchiveFlagsAreOneChoice() async {
        #expect(MemoArchiveScope.allCases.count == 3, "a scope was added without a case here")

        for scope in MemoArchiveScope.allCases {
            let paths = LockedValue<[String]>([])
            let search = Self.search { request, _, _ in
                paths.set(paths.get() + [request.path ?? ""])
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }

            // A tag comes along so the query is never the empty one, which is the plain timeline
            // and is deliberately not run as a search at all.
            var filters = SearchFilters.empty.toggling("travel")
            filters.archive = scope
            search.apply(filters)
            await search.settled()

            let requests = paths.get().map { Self.sent($0) }
            #expect(requests.count == 1, "\(scope): \(requests.count) requests")
            guard let request = requests.first else { continue }
            #expect(request["tag"] == ["travel"], "\(scope): control, the request is the filter's")

            let includes = request["include_archived"] ?? []
            let onlys = request["archived_only"] ?? []
            #expect(
                !(includes.contains("true") && onlys.contains("true")),
                "\(scope) put both archive flags on one request"
            )
            switch scope {
            case .active:
                // Neither, not `false`: the server defaults both to False, so the absence IS the
                // request the app has always sent.
                #expect(includes.isEmpty, "\(scope) asked for the archived ones")
                #expect(onlys.isEmpty, "\(scope) asked for only the archived ones")
            case .including:
                #expect(includes == ["true"])
                #expect(onlys.isEmpty)
            case .only:
                #expect(includes.isEmpty)
                #expect(onlys == ["true"])
            }
        }

        // Control: the value type underneath CAN say both — it is faithful to a server that takes
        // two flags. So the exclusion above is this seam refusing to build it, not an
        // impossibility that would hold however the sheet were wired.
        let both = MemoQuery(tags: ["travel"], includeArchived: true, archivedOnly: true)
            .parameters(in: .current)
        #expect(both.includeArchived == true)
        #expect(both.archivedOnly == true)
    }

    // MARK: - paging

    /// The cursor carries no filter state — it is base64 `created_at|id`
    /// (memos-ng `app/services/memos.py:43-49`) — so every page has to resend every filter. A
    /// visibility dropped on the second page widens the list halfway down it: private memos
    /// appearing under a heading that says Protected, which is the one filter here whose failure
    /// shows someone something they asked not to see.
    @Test("a visibility choice survives paging")
    func aVisibilityChoiceIsResentOnEveryPage() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            return path.contains("cursor=page-2")
                ? Stub.json(Stub.memoList(["b"], nextCursor: nil))
                : Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
        }
        let search = MemoSearch(
            handle: client.handle, baseURL: Stub.baseURL, pageSize: 1)

        var filters = SearchFilters.empty
        filters.visibility = .protected
        search.apply(filters)
        await search.settled()
        await search.results.loadMore(using: client.handle, baseURL: Stub.baseURL)

        #expect(search.results.memos.map(\.uid) == ["a", "b"], "the list did not page")
        let requests = paths.get().map { Self.sent($0) }
        #expect(requests.count == 2)
        for (index, request) in requests.enumerated() {
            #expect(
                request["visibility"] == ["PROTECTED"],
                "page \(index + 1) dropped the visibility"
            )
        }
        #expect(requests[0]["cursor"] == nil, "the first page asked from a cursor")
        #expect(
            requests[1]["cursor"] == ["page-2"],
            "control: the second request really is the next page"
        )

        // Control: without a visibility chosen neither page carries one, so the assertion above is
        // the choice travelling and not a parameter that is always sent.
        let plainPaths = LockedValue<[String]>([])
        let plainClient = Stub.client { request, _, _ in
            let path = request.path ?? ""
            plainPaths.set(plainPaths.get() + [path])
            return path.contains("cursor=page-2")
                ? Stub.json(Stub.memoList(["b"], nextCursor: nil))
                : Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
        }
        let plain = MemoSearch(
            handle: plainClient.handle, baseURL: Stub.baseURL, pageSize: 1)
        plain.apply(SearchFilters.empty.toggling("travel"))
        await plain.settled()
        await plain.results.loadMore(using: plainClient.handle, baseURL: Stub.baseURL)
        for request in plainPaths.get().map({ Self.sent($0) }) {
            #expect(request["visibility"] == nil, "an unchosen visibility reached the wire")
            #expect(request["tag"] == ["travel"], "control: this page carried its own filter")
        }
    }

    // MARK: - the filters and the field

    /// A filter and a term are one question, not two. Setting a filter while a word is in the
    /// field has to keep the word, and typing a word while a filter is set has to keep the filter
    /// — either one forgetting the other is a list that answers something nobody asked.
    @Test("a filter and a typed term travel as one request")
    func aFilterComposesWithTheTerm() async {
        let paths = LockedValue<[String]>([])
        let search = MemoSearch(
            handle: Stub.client { request, _, _ in
                paths.set(paths.get() + [request.path ?? ""])
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }.handle,
            baseURL: Stub.baseURL,
            coalescing: .zero
        )

        search.typed("travel")
        await search.settled()
        search.apply(SearchFilters.empty.toggling("trip"))
        await search.settled()

        let requests = paths.get().map { Self.sent($0) }
        #expect(requests.count == 2)
        #expect(requests[0]["q"] == ["travel"])
        #expect(requests[0]["tag"] == nil, "control: the first request carried no filter")
        #expect(requests[1]["q"] == ["travel"], "setting a filter threw the term away")
        #expect(requests[1]["tag"] == ["trip"], "the filter never reached the wire")

        // The other direction: a keystroke after a filter is set keeps the filter.
        search.typed("travelling")
        await search.settled()
        let typed = paths.get().map { Self.sent($0) }
        #expect(typed.count == 3)
        #expect(typed[2]["q"] == ["travelling"])
        #expect(typed[2]["tag"] == ["trip"], "typing threw the filter away")
    }

    /// The re-ask that had nowhere to land.
    ///
    /// A filtered search is in flight. One character is typed, which sends nothing and CANCELS it;
    /// the field is cleared again before that cancellation has unwound, and the filter is re-asked
    /// — the identical query, because the filter never changed.
    ///
    /// Identical is the whole problem. `TimelineStore.setQuery` returns early for a query it is
    /// already reading, so the lineage does not move; and `refresh` refuses a lineage that is
    /// already being loaded (`TimelineStore.swift:135`), which the cancelled request still holds
    /// because its `defer` has not run yet. The re-ask therefore issued NO request at all, and
    /// then answered from whatever rows happened to be on hand. Nothing was left to try again: no
    /// request in flight, no trigger, a filtered sheet sitting on a lie.
    ///
    /// The first request is held open by a gate that ignores cancellation, so the window the
    /// defect lives in is held open with it rather than raced for.
    @Test("a cleared field re-asks its filter, and the re-ask reaches the network")
    func aReAskAfterACancelledRequestStillReachesTheNetwork() async {
        let gate = HeldRequest()
        let calls = Counter()
        let paths = LockedValue<[String]>([])
        let search = MemoSearch(
            handle: Stub.client { request, _, _ in
                paths.set(paths.get() + [request.path ?? ""])
                calls.increment()
                guard calls.count > 1 else {
                    // The one that gets cancelled. It answers with nothing, so rows from it could
                    // never be mistaken for the re-ask's.
                    await gate.enter()
                    return Stub.json(Stub.page([], nextCursor: nil))
                }
                return Stub.json(Stub.memoList(["found"], nextCursor: nil))
            }.handle,
            baseURL: Stub.baseURL
        )

        search.apply(SearchFilters.empty.toggling("trip"))
        // Control: the first request really is in flight and parked, so what follows cancels
        // something rather than arriving before anything started.
        await gate.entered()

        // One character, then straight back out — both before the cancelled request can unwind.
        search.typed("t")
        search.typed("")

        await gate.release()
        await search.settled()

        let sent = paths.get()
        #expect(
            sent.count == 2,
            "the re-asked filter never reached the network: \(sent.count) request(s) in all"
        )
        let uids: [String] = search.results.memos.map(\.uid)
        #expect(uids == ["found"], "the list is not what the re-ask brought back")
        #expect(
            search.outcome == .matched,
            "the sheet answered from rows no request of its own had fetched"
        )
    }

    /// Clearing the field with a filter still set is not the end of the search — the filter IS a
    /// search, and what has to come back is the filter on its own. With nothing set at all it is
    /// exactly the cleared field this sheet has always had: nothing sent, and back to the
    /// invitation.
    @Test("an empty field is a search while a filter is set, and nothing without one")
    func anEmptyFieldStillSearchesItsFilters() async {
        let paths = LockedValue<[String]>([])
        let search = MemoSearch(
            handle: Stub.client { request, _, _ in
                paths.set(paths.get() + [request.path ?? ""])
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }.handle,
            baseURL: Stub.baseURL,
            coalescing: .zero
        )

        search.apply(SearchFilters.empty.toggling("trip"))
        await search.settled()
        search.typed("travel")
        await search.settled()
        search.typed("")
        await search.settled()

        let requests = paths.get().map { Self.sent($0) }
        #expect(requests.count == 3, "clearing the field sent \(requests.count) requests in all")
        #expect(requests[1]["q"] == ["travel"], "control: the middle request carried the term")
        #expect(
            requests[2]["tag"] == ["trip"],
            "clearing the field abandoned a search the filter still asks"
        )
        #expect(requests[2]["q"] == nil, "the cleared term was still on the wire")
        #expect(search.outcome == .matched, "a filtered search read as an empty sheet")
        #expect(!search.results.memos.isEmpty, "clearing the field emptied the filtered list")

        // Control: with the filter taken off too, the empty field is the invitation again and
        // nothing more is asked of the server. The rows already fetched stay where they are —
        // that is `TimelineStore.setQuery`'s own rule, and the list nobody is looking at any more
        // is the sheet's, not the timeline's.
        search.apply(.empty)
        await search.settled()
        #expect(paths.get().count == 3, "the plain timeline was fetched as a search")
        #expect(search.outcome == .idle)
        #expect(search.results.query.isEmpty, "the abandoned filter is still what the list asks")
    }
}

/// One request held open until the test lets it go, and the test's own wait for it to get there.
///
/// Deliberately NOT cancellation-aware, which is the point of it. The defect this suite pins lives
/// in the window between a request being cancelled and its `defer` running, and a gate that let go
/// when the task was cancelled would close that window before a test could look through it. Both
/// halves are continuations rather than polls: the request's arrival resumes the test, and the
/// test's release resumes the request.
private actor HeldRequest {
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

    /// Called from the test: returns once the request has reached the gate.
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
