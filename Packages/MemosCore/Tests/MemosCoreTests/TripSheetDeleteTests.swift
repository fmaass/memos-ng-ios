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
        #expect(server.calls.of(Self.tags).count == 2, "overlapping counts must still refuse")
        release.open()
        await read.value

        #expect(outcome?.deleted == [TripWire.uid(0)], "control: the picture was deleted")
        #expect(trips.revision == revision, "control: the record reload moves no revision")
        #expect(server.calls.of(TripWire.get).count == 1, "control: the trip was reloaded")
        #expect(store.tagCounts.isEmpty, "the pre-delete count survived")
        #expect(!store.tagCountsLoaded, "a dropped count is not a loaded answer")

        await store.loadTagCounts(using: handle)
        #expect(store.tagCounts == [LibraryTag(name: Self.tag, count: 2)])
        #expect(store.tagCountsLoaded, "the stale read left the count slot occupied")
        #expect(server.calls.of(Self.tags).count == 3)
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
