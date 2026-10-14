import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A sheet answer cannot be reconciled by picture id: counts carry none, and an extremum does
/// not say which picture takes its place. A delete must retire the whole answer (MEMNG-795).
@MainActor
@Suite("Trip sheet — reads across a picture delete")
struct TripSheetDeleteTests {
    private nonisolated static let tags = "attachment_tags_api_attachments_tags_get"
    private nonisolated static let tag = "portugal2026"

    private func server(
        deleteStatus: HTTPResponse.Status = .noContent, hold: TripServer.Hold? = nil
    ) -> TripServer {
        let box = LockedValue<TripServer?>(nil)
        let server = TripServer(
            answer: { request, operation in
                let pictures = box.get()?.rows.first?.pictures ?? []
                if operation == Self.tags {
                    return Stub.json(
                        #"[{"name":"portugal2026","count":\#(pictures.count)}]"#)
                }
                guard operation == TripWire.library else { return nil }
                let newest = TripWire.query(request.path ?? "", "order") == "taken_desc"
                let index = newest ? pictures.max() : pictures.min()
                return TripWire.page(index.map { [$0] } ?? [])
            }, deleteStatus: deleteStatus, hold: hold)
        box.set(server)
        server.seed(title: "Portugal 2026", tag: Self.tag, pictures: [0, 1, 2])
        return server
    }

    private static let before = TripTagSpan(
        firstTaken: TripWire.taken(0), lastTaken: TripWire.taken(2))
    private static let after = TripTagSpan(
        firstTaken: TripWire.taken(1), lastTaken: TripWire.taken(2))

    @Test("counts held across a delete are dropped, and a later read can publish")
    func heldCountsAreDropped() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = server(hold: { operation, count in
            guard operation == Self.tags, count == 2 else { return }
            entered.open()
            await release.wait()
        })
        let (trips, store) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        await store.drain(try #require(trips.trips.first), using: handle, baseURL: Stub.baseURL)
        await store.loadTagCounts(using: handle)
        #expect(store.tagCounts == [LibraryTag(name: Self.tag, count: 3)], "control")
        let revision = trips.revision

        let read = Task { await store.loadTagCounts(using: handle) }
        #expect(await entered.wait(), "the count response was never held")
        let outcome = await store.delete([TripWire.uid(0)], using: handle, baseURL: Stub.baseURL)
        await store.loadTagCounts(using: handle)
        #expect(server.calls.of(Self.tags).count == 3, "the post-delete count read was refused")
        #expect(store.tagCounts == [LibraryTag(name: Self.tag, count: 2)], "it did not publish")
        release.open()
        await read.value

        #expect(outcome?.deleted == [TripWire.uid(0)], "control: the picture was deleted")
        #expect(trips.revision == revision, "control: the record reload moves no revision")
        #expect(server.calls.of(TripWire.get).count == 1, "control: the trip was reloaded")
        #expect(
            store.tagCounts == [LibraryTag(name: Self.tag, count: 2)],
            "the held pre-delete count was published over the post-delete one")
        #expect(store.tagCountsLoaded, "the dropped pre-delete count unloaded the published one")

        await store.loadTagCounts(using: handle)
        #expect(store.tagCounts == [LibraryTag(name: Self.tag, count: 2)])
        #expect(store.tagCountsLoaded, "the stale read left the count slot occupied")
        #expect(server.calls.of(Self.tags).count == 4)
        await checkFailedDeleteKeepsReads()
    }

    @Test("a count refusal held across a delete ends the current session without a sentence")
    func heldCountRefusalEndsTheSessionWithoutASentence() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, credential in
                Stub.client(token: credential) { _, _, operation in
                    switch operation {
                    case Self.tags:
                        entered.open()
                        await release.wait()
                        return Stub.empty(.unauthorized)
                    case TripServer.deleteAttachment:
                        return Stub.empty(.noContent)
                    default:
                        return Stub.json(Stub.user)
                    }
                }
            },
            lastKnownUser: StubLastKnownUser()
        )
        await session.signIn(
            serverAddress: Stub.baseURL.absoluteString, token: "memos_pat_trips")
        let handle = try #require(session.activeHandle, "the premise: a signed-in session")
        let (_, store) = await TripSeeder(server: server()).members(
            onUnauthorized: { refusal in
                await session.handle(refusal)
            })
        store.reports(to: session)
        let revision = store.deletionRevision

        let read = Task { await store.loadTagCounts(using: handle) }
        #expect(await entered.wait(), "the count response was never held")
        let outcome = await store.delete([TripWire.uid(0)], using: handle, baseURL: Stub.baseURL)
        #expect(outcome?.deleted == [TripWire.uid(0)], "control: the picture was deleted")
        #expect(store.deletionRevision == revision + 1, "control: the delete moved the fence")
        #expect(session.activeHandle?.generation == handle.generation, "the credential is current")
        #expect(store.lastError == nil, "control: the delete wrote no sentence")
        release.open()
        await read.value

        #expect(session.state == .signedOut, "the session survived a refusal of its own credential")
        #expect(store.lastError == nil, "the stale count refusal wrote a sentence")
    }

    @Test(
        "either extremum held across a delete retires the span for its caller and joiner",
        arguments: [1, 2])
    func heldSpanAndJoinerAreDropped(extremum: Int) async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = server(hold: { operation, count in
            guard operation == TripWire.library, count == extremum + 2 else { return }
            entered.open()
            await release.wait()
        })
        let (trips, store) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        await store.drain(try #require(trips.trips.first), using: handle, baseURL: Stub.baseURL)
        await store.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
        #expect(store.spans[Self.tag] == Self.before, "control")
        let revision = trips.revision
        let joined = TripLatch()
        store.onSpanJoin = { joined.open() }

        let read = Task {
            await store.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the extremum response was never held")
        let joiner = Task {
            await store.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
            return store.spans[Self.tag]
        }
        #expect(await joined.wait(), "the second caller did not join")
        let outcome = await store.delete([TripWire.uid(0)], using: handle, baseURL: Stub.baseURL)
        release.open()
        await read.value

        #expect(outcome?.deleted == [TripWire.uid(0)], "control: the picture was deleted")
        #expect(trips.revision == revision, "control: the record reload moves no revision")
        #expect(await joiner.value == nil, "the joiner received the pre-delete span")
        #expect(store.spans[Self.tag] == nil, "the pre-delete span survived")
        #expect(
            server.calls.of(TripWire.library).count == extremum + 2,
            "a stale first extremum must not request the second")

        await store.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
        #expect(store.spans[Self.tag] == Self.after, "a fresh pair must still publish")
        #expect(server.calls.of(TripWire.library).count == extremum + 4)
    }

    @Test("a post-delete span read owns a new slot that the old read cannot clear")
    func aPostDeleteSpanDoesNotJoinTheOldRead() async {
        let oldEntered = TripLatch()
        let oldRelease = TripLatch()
        let freshEntered = TripLatch()
        let freshRelease = TripLatch()
        let server = server(hold: { operation, count in
            guard operation == TripWire.library else { return }
            if count == 1 {
                oldEntered.open()
                await oldRelease.wait(seconds: 30)
            }
            if count == 2 {
                freshEntered.open()
                await freshRelease.wait()
            }
        })
        let (_, store) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        let old = Task {
            await store.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await oldEntered.wait(), "the old read was never held")
        let outcome = await store.delete([TripWire.uid(0)], using: handle, baseURL: Stub.baseURL)
        #expect(outcome?.deleted == [TripWire.uid(0)], "control")
        let fresh = Task {
            await store.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
            return store.spans[Self.tag]
        }
        let sent = await freshEntered.wait()
        #expect(sent, "a post-delete caller joined the old span")
        guard sent else {
            oldRelease.open()
            freshRelease.open()
            await old.value
            _ = await fresh.value
            return
        }
        oldRelease.open()
        await old.value

        let joined = TripLatch()
        store.onSpanJoin = { joined.open() }
        let joiner = Task {
            await store.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
            return store.spans[Self.tag]
        }
        #expect(await joined.wait(), "the old read cleared the fresh read's slot")
        freshRelease.open()
        #expect(await fresh.value == Self.after)
        #expect(await joiner.value == Self.after)
        #expect(server.calls.of(TripWire.library).count == 3)
    }

    private func checkFailedDeleteKeepsReads() async {
        let countEntered = TripLatch()
        let spanEntered = TripLatch()
        let countRelease = TripLatch()
        let spanRelease = TripLatch()
        let server = server(
            deleteStatus: .internalServerError,
            hold: { operation, count in
                if operation == Self.tags {
                    countEntered.open()
                    await countRelease.wait()
                }
                if operation == TripWire.library, count == 1 {
                    spanEntered.open()
                    await spanRelease.wait()
                }
            }
        )
        let (_, store) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        let counts = Task { await store.loadTagCounts(using: handle) }
        let span = Task {
            await store.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await countEntered.wait())
        #expect(await spanEntered.wait())
        let outcome = await store.delete([TripWire.uid(0)], using: handle, baseURL: Stub.baseURL)
        #expect(outcome?.deleted == [], "control: the server deleted nothing")
        countRelease.open()
        spanRelease.open()
        await counts.value
        await span.value

        #expect(store.tagCounts == [LibraryTag(name: Self.tag, count: 3)])
        #expect(store.tagCountsLoaded)
        #expect(store.spans[Self.tag] == Self.before)
    }
}

/// A picture deleted anywhere — the Library, the Timeline, a run a renewal stopped — retires the
/// New trip sheet's counts and spans, and a trip that held it is read again (MEMNG-809).
@MainActor
@Suite("Trip sheet — invalidation from every delete path (MEMNG-809)")
struct TripSheetInvalidationTests {
    private nonisolated static let tags = "attachment_tags_api_attachments_tags_get"
    private nonisolated static let tag = "portugal2026"
    private nonisolated static let listMemos = "list_memos_api_memos_get"
    private nonisolated static let deleteMemo = "delete_memo_api_memos__uid__delete"
    private nonisolated static let memo = "m1"

    private static let before = TripTagSpan(
        firstTaken: TripWire.taken(0), lastTaken: TripWire.taken(2))
    private static let after = TripTagSpan(
        firstTaken: TripWire.taken(1), lastTaken: TripWire.taken(2))

    /// One trip tagged with pictures 0, 1 and 2; one memo carrying picture 0. Counts and extrema
    /// are read from what the server holds when they are asked.
    private func server(
        deleteStatus: HTTPResponse.Status = .noContent, hold: TripServer.Hold? = nil
    ) -> TripServer {
        let box = LockedValue<TripServer?>(nil)
        let server = TripServer(
            answer: { request, operation in
                let pictures = box.get()?.rows.first?.pictures ?? []
                switch operation {
                case Self.tags:
                    return Stub.json(
                        #"[{"name":"portugal2026","count":\#(pictures.count)}]"#)
                case TripWire.library:
                    let newest = TripWire.query(request.path ?? "", "order") == "taken_desc"
                    let index = newest ? pictures.max() : pictures.min()
                    return TripWire.page(index.map { [$0] } ?? [])
                case Self.listMemos:
                    let picture = Stub.attachment(uid: TripWire.uid(0), status: "ready")
                    return Stub.json(Stub.page([Stub.memo(uid: Self.memo, attachments: [picture])]))
                case Self.deleteMemo:
                    if let trip = box.get()?.rows.first?.uid {
                        box.get()?.edit(trip) { row in row.pictures.removeAll { $0 == 0 } }
                    }
                    return Stub.empty(.noContent)
                default:
                    return nil
                }
            }, deleteStatus: deleteStatus, hold: hold)
        box.set(server)
        server.seed(title: "Portugal 2026", tag: Self.tag, pictures: [0, 1, 2])
        return server
    }

    /// The sheet's count and span, read before the delete: the control every case starts from.
    private func loadSheet(_ members: TripMemberStore, _ handle: SessionHandle) async {
        await members.loadTagCounts(using: handle)
        await members.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
        #expect(members.tagCountsLoaded, "control: the count was read")
        #expect(members.spans[Self.tag] == Self.before, "control: the span was read")
    }

    /// Nothing cached survives, and the next span read asks for both extrema and publishes the
    /// first date the delete moved.
    private func expectRetired(
        _ members: TripMemberStore, _ server: TripServer, _ handle: SessionHandle,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(
            members.spans[Self.tag] == nil, "the pre-delete span survived",
            sourceLocation: sourceLocation)
        #expect(
            !members.tagCountsLoaded, "the pre-delete count survived",
            sourceLocation: sourceLocation)
        let sent = server.calls.of(TripWire.library).count
        await members.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
        #expect(
            server.calls.of(TripWire.library).count == sent + 2, sourceLocation: sourceLocation)
        #expect(members.spans[Self.tag] == Self.after, sourceLocation: sourceLocation)
    }

    private func library(reportingTo members: TripMemberStore) -> MediaLibraryStore {
        let library = MediaLibraryStore()
        library.onPicturesDeleted = members.picturesDeletedHook(baseURL: { Stub.baseURL })
        return library
    }

    private func timeline(
        reportingTo members: TripMemberStore, _ handle: SessionHandle
    ) async -> TimelineStore {
        let timeline = TimelineStore()
        timeline.onPicturesDeleted = members.picturesDeletedHook(baseURL: { Stub.baseURL })
        await timeline.refresh(using: handle, baseURL: Stub.baseURL)
        #expect(timeline.memos.map(\.uid) == [Self.memo], "control: the memo was read")
        return timeline
    }

    @Test("a Library delete of a tag's oldest picture retires the sheet's count and span")
    func aLibraryDeleteInvalidates() async {
        let server = server()
        let (_, members) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        await loadSheet(members, handle)

        let outcome = await library(reportingTo: members).delete([TripWire.uid(0)], using: handle)
        #expect(outcome?.deleted == [TripWire.uid(0)], "control: the picture was deleted")
        await expectRetired(members, server, handle)
    }

    @Test("a Library delete that landed nothing retires nothing")
    func aFailedLibraryDeleteKeepsTheSheet() async {
        let server = server(deleteStatus: .internalServerError)
        let (_, members) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        await loadSheet(members, handle)
        let revision = members.deletionRevision

        let outcome = await library(reportingTo: members).delete([TripWire.uid(0)], using: handle)
        #expect(outcome?.deleted == [], "control: the server deleted nothing")
        #expect(members.deletionRevision == revision, "a delete of nothing moved the fence")
        #expect(members.tagCountsLoaded, "a delete of nothing retired the count")
        #expect(members.spans[Self.tag] == Self.before, "a delete of nothing retired the span")
    }

    @Test("a Timeline memo delete retires the sheet's count and span for its pictures")
    func aTimelineMemoDeleteInvalidates() async {
        let server = server()
        let (_, members) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        let timeline = await timeline(reportingTo: members, handle)
        await loadSheet(members, handle)

        #expect(await timeline.delete(uid: Self.memo, using: handle), "control: memo deleted")
        #expect(members.deleted == [TripWire.uid(0)], "the memo's picture was not reported")
        await expectRetired(members, server, handle)
    }

    @Test("a Timeline attachment delete retires the sheet's count and span")
    func aTimelineAttachmentDeleteInvalidates() async {
        let server = server()
        let (_, members) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        let timeline = await timeline(reportingTo: members, handle)
        await loadSheet(members, handle)

        let removed = await timeline.deleteAttachment(
            uid: TripWire.uid(0), from: Self.memo, using: handle)
        #expect(removed, "control: the attachment was deleted")
        await expectRetired(members, server, handle)
    }

    @Test("a Library run a renewal stopped invalidates once, for the picture that landed")
    func aStoppedLibraryRunInvalidatesWhatLanded() async {
        let entered = TripLatch()
        let release = TripLatch()
        let server = server(hold: { operation, count in
            guard operation == TripServer.deleteAttachment, count == 1 else { return }
            entered.open()
            await release.wait(seconds: 30)
        })
        let (_, members) = await TripSeeder(server: server).members()
        let client = server.client
        let issued = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: issued)
        await loadSheet(members, issued)
        let library = library(reportingTo: members)
        library.reports(to: session)
        let revision = members.deletionRevision

        let run = Task {
            await library.delete(
                [TripWire.uid(0), TripWire.uid(1), TripWire.uid(2)], using: issued)
        }
        #expect(await entered.wait(), "the first DELETE never went out")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.open()
        let outcome = await run.value

        #expect(outcome?.stoppedForSessionChange == true, "control: the renewal stopped the run")
        #expect(outcome?.deleted == [TripWire.uid(0)], "control: one picture landed")
        #expect(members.deletionRevision == revision + 1, "not invalidated exactly once")
        #expect(members.deleted == [TripWire.uid(0)], "the landed picture was not reported")
        await expectRetired(members, server, issued)
    }

    @Test("a Library delete of a trip's member reads that trip's record again")
    func aLibraryDeleteReloadsTheTripThatHeldIt() async throws {
        let server = server()
        let (trips, members) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        let trip = try #require(trips.trips.first)
        await members.drain(trip, using: handle, baseURL: Stub.baseURL)
        #expect(
            members.members(for: trip).map(\.id).contains(TripWire.uid(0)),
            "control: the picture was drained as a member")
        let gets = server.calls.of(TripWire.get).count

        let outcome = await library(reportingTo: members).delete([TripWire.uid(0)], using: handle)
        #expect(outcome?.deleted == [TripWire.uid(0)], "control: the picture was deleted")
        #expect(
            server.calls.of(TripWire.get).count == gets + 1,
            "the trip that held the picture was not read again")
        #expect(!members.members(for: trip).map(\.id).contains(TripWire.uid(0)))
    }

    @Test("a post-delete count read owns a new slot that the held pre-delete read cannot free")
    func aPostDeleteCountOwnsItsSlot() async {
        let oldEntered = TripLatch()
        let oldRelease = TripLatch()
        let freshEntered = TripLatch()
        let freshRelease = TripLatch()
        let server = server(hold: { operation, count in
            guard operation == Self.tags else { return }
            if count == 2 {
                oldEntered.open()
                await oldRelease.wait(seconds: 30)
            }
            if count == 3 {
                freshEntered.open()
                await freshRelease.wait(seconds: 30)
            }
        })
        let (_, members) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        await members.loadTagCounts(using: handle)
        #expect(members.tagCounts == [LibraryTag(name: Self.tag, count: 3)], "control")

        let old = Task { await members.loadTagCounts(using: handle) }
        #expect(await oldEntered.wait(), "the pre-delete read was never held")
        let outcome = await members.delete([TripWire.uid(0)], using: handle, baseURL: Stub.baseURL)
        #expect(outcome?.deleted == [TripWire.uid(0)], "control: the picture was deleted")
        let fresh = Task { await members.loadTagCounts(using: handle) }
        let sent = await freshEntered.wait()
        #expect(sent, "the post-delete count read was refused, not sent")
        guard sent else {
            oldRelease.open()
            freshRelease.open()
            await old.value
            await fresh.value
            return
        }
        oldRelease.open()
        await old.value

        await members.loadTagCounts(using: handle)
        #expect(
            server.calls.of(Self.tags).count == 3,
            "the held pre-delete read's end freed the post-delete read's slot")
        freshRelease.open()
        await fresh.value
        #expect(members.tagCounts == [LibraryTag(name: Self.tag, count: 2)])
        #expect(members.tagCountsLoaded)
    }

    @Test("a delete that lands after the identity changed leaves the new identity's sheet alone")
    func aDeleteAfterAnIdentityChangeIsDropped() async {
        let entered = TripLatch()
        let release = TripLatch()
        let server = server(hold: { operation, count in
            guard operation == TripServer.deleteAttachment, count == 1 else { return }
            entered.open()
            await release.wait(seconds: 30)
        })
        let (_, members) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        let library = library(reportingTo: members)

        let run = Task { await library.delete([TripWire.uid(0)], using: handle) }
        #expect(await entered.wait(), "the DELETE never went out")
        members.sessionIdentityChanged()
        await members.loadTagCounts(using: handle)
        await members.loadSpan(ofTag: Self.tag, using: handle, baseURL: Stub.baseURL)
        let counts = members.tagCounts
        let revision = members.deletionRevision
        #expect(members.tagCountsLoaded, "control: the new identity read its count")
        #expect(members.spans[Self.tag] == Self.after, "control: the new identity read its span")
        release.open()
        let outcome = await run.value

        #expect(outcome?.deleted == [TripWire.uid(0)], "control: the picture was deleted")
        #expect(members.deleted.isEmpty, "an old identity's delete wrote into the new one's store")
        #expect(members.deletionRevision == revision, "an old identity's delete moved the fence")
        #expect(members.tagCountsLoaded, "an old identity's delete retired the new count")
        #expect(members.tagCounts == counts)
        #expect(members.spans[Self.tag] == Self.after, "an old identity's delete retired the span")
    }
}
