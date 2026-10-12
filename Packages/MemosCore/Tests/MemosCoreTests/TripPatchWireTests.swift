import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

/// What a trip change puts on the wire, through the REAL generated client and the factory's
/// middleware over a scripted transport: a cleared field is an explicit `null`, a left one is an
/// absent key, and nothing else the client sends is touched. `@testable` for nothing but symmetry
/// with the other trip suites.
@MainActor
@Suite("Trip patch wire")
struct TripPatchWireTests {
    private let root = TripWire.root()

    private func store() -> TripStore {
        TripStore(identity: TripWire.alice, root: root)
    }

    private nonisolated static func instant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("patch encodes clear vs leave (explicit null vs absent key, asserted on the body bytes)")
    func patchEncodesClearAndLeave() async throws {
        let calls = TripCalls()
        let client = Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            return Stub.json(TripWire.collection("t1", title: "Lisbon"))
        }
        let store = store()
        let patch = TripPatch(
            title: .set("Lisbon"),
            tag: .clear,
            spanStart: .set(Self.instant("2026-09-12T22:00:00Z")),
            spanEnd: .set(Self.instant("2026-09-20T21:59:59Z")),
            tz: .leave,
            cover: .clear
        )
        _ = try await store.update(
            uid: "t1", patch: patch, using: client.handle, baseURL: Stub.baseURL)

        let sent = try #require(calls.of(TripWire.patch).first, "no PATCH was sent")
        let expected =
            #"{"coverAttachmentUid":null,"spanEnd":"2026-09-20T21:59:59Z","#
            + #""spanStart":"2026-09-12T22:00:00Z","tag":null,"title":"Lisbon"}"#
        #expect(String(decoding: sent.body, as: UTF8.self) == expected)
        let object = Stub.object(sent.body)
        #expect(object["tag"] is NSNull, "a cleared tag was not sent as null")
        #expect(object["coverAttachmentUid"] is NSNull, "a cleared cover was not sent as null")
        #expect(object.keys.contains("tz") == false, "a left zone was sent")

        // Control: the same change with the zone set and nothing cleared carries no null at all.
        let plain = TripPatch(title: .set("Lisbon"), tz: .set("Europe/Lisbon"))
        _ = try await store.update(
            uid: "t1", patch: plain, using: client.handle, baseURL: Stub.baseURL)
        let second = try #require(calls.of(TripWire.patch).last)
        #expect(!String(decoding: second.body, as: UTF8.self).contains("null"))
        #expect(Stub.object(second.body)["tz"] as? String == "Europe/Lisbon")
    }

    @Test("a different operation is untouched inside a withValue")
    func otherOperationsAreUntouched() async throws {
        let calls = TripCalls()
        let client = Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            switch operation {
            case TripWire.create: return Stub.json(TripWire.collection("t9"), status: .created)
            case TripWire.list: return Stub.json("[\(TripWire.collection("t9"))]")
            default: return Stub.empty(.noContent)
            }
        }
        let store = store()
        let frozen = NewTripRequest(scope: TripWire.alice, title: "Porto", tag: "porto")
        _ = try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
        try await ExplicitNulls.$fields.withValue(["tag", "spanStart", "title"]) {
            _ = try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
            await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        }

        let creates = calls.of(TripWire.create)
        #expect(creates.count == 2)
        let outside = try #require(creates.first).body
        let inside = try #require(creates.last).body
        #expect(outside == inside, "the retry inside the scope differed")
        #expect(!String(decoding: inside, as: UTF8.self).contains("null"))
        let listed = try #require(calls.of(TripWire.list).first)
        #expect(listed.body.isEmpty, "a GET gained a body")
    }

    @Test("a clear and a leave on one uid are different payloads: one request and one busy")
    func clearAndLeaveAreDifferentPayloads() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            let answer = Stub.json(TripWire.collection("t1", title: "Same"))
            guard operation == TripWire.patch else { return answer }
            entered.open()
            await release.wait()
            return answer
        }
        let store = store()
        let first = Task {
            try await store.update(
                uid: "t1", patch: TripPatch(title: .set("Same"), tag: .clear),
                using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first PATCH never reached the wire")
        await #expect(throws: TripStore.Failure.busy) {
            try await store.update(
                uid: "t1", patch: TripPatch(title: .set("Same")), using: client.handle,
                baseURL: Stub.baseURL)
        }
        release.open()
        _ = try await first.value

        #expect(
            calls.of(TripWire.patch).count == 1, "the leave joined the clear or reached the wire")
        let sent = try #require(calls.of(TripWire.patch).first)
        #expect(Stub.object(sent.body)["tag"] is NSNull)
    }

    @Test("an answer this device cannot read fails the way every store reports one")
    func unreadableAnswerIsReportedAsTheHouseDoes() async throws {
        let client = Stub.client { _, _, operation in
            switch operation {
            case TripWire.list: return Stub.json(#"{"not":"a list"}"#)
            default: return Stub.json(#"{"uid":17}"#)
            }
        }
        let store = store()
        let result: Result<Trip, any Error>
        do {
            result = .success(
                try await store.update(
                    uid: "t1", patch: TripPatch(title: .set("x")), using: client.handle,
                    baseURL: Stub.baseURL))
        } catch {
            result = .failure(error)
        }

        guard case .failure(let error) = result, let failure = error as? TripStore.Failure,
            case .failed(let apiError) = failure
        else {
            Issue.record("an unreadable answer did not fail as .failed: \(result)")
            return
        }
        guard case .unexpected = apiError else {
            Issue.record("classified as \(apiError), not as StoreFailure.reportable classifies it")
            return
        }
        #expect(failure.errorDescription == apiError.errorDescription)
        #expect(!(failure.errorDescription ?? "").isEmpty)

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.lastError != nil, "an unreadable list went quiet")
    }
}
