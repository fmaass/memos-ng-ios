import Foundation
import MemosAPI
import MemosCore
import Testing

/// A pass guest's memo is the trip's, not the home timeline's (MEMNG-1164). The server leaves guest
/// memos out of `GET /api/memos` unless the read says `guest=include`, so the home timeline keeps
/// them out by NOT asking — and a guest memo that reaches the app anyway still says who sent it.
@MainActor
@Suite("Guest memos on the home timeline")
struct GuestMemoTimelineTests {
    /// A memo as the server writes one a pass guest sent in: owned by the pass's account, with the
    /// contributor in `guest`. `name: nil` is a guest who gave no name.
    nonisolated static func guestMemo(_ uid: String, name: String?) -> String {
        let contributor = name.map { "\"\($0)\"" } ?? "null"
        return """
            {"uid":"\(uid)","owner":"fabian","mine":true,"content":"from the beach",\
            "visibility":"PRIVATE","pinned":false,"created_at":"2026-08-23T09:00:00Z",\
            "updated_at":"2026-08-23T09:00:00.443000Z","archived_at":null,"tags":[],\
            "attachments":[],"guest":{"contributor_name":\(contributor),"pass_uid":"pass-1"}}
            """
    }

    @Test("the home timeline never asks for guest memos, on its first page or the next")
    func theHomeTimelineDoesNotAskForGuests() async {
        let store = TimelineStore(pageSize: 1)
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            return path.contains("cursor=")
                ? Stub.json(Stub.memoList(["b"], nextCursor: nil))
                : Stub.json(Stub.memoList(["a"], nextCursor: "cursor-1"))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)

        let sent = paths.get()
        #expect(sent.count == 2, "not a first page and a next one: \(sent)")
        for path in sent {
            let names = URLComponents(string: path)?.queryItems?.map(\.name) ?? []
            #expect(!names.contains("guest"), "the home timeline asked about guests: \(path)")
        }
        #expect(store.memos.map(\.uid) == ["a", "b"])
    }

    @Test("a guest memo that reaches the home timeline carries its contributor; the owner's none")
    func aGuestMemoCarriesItsContributor() async throws {
        let store = TimelineStore()
        let client = Stub.client { _, _, _ in
            Stub.json(
                Stub.page([
                    Self.guestMemo("g1", name: "Anna"), Self.guestMemo("g2", name: nil),
                    Stub.memo(uid: "own"),
                ]))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let byUID = Dictionary(uniqueKeysWithValues: store.memos.map { ($0.uid, $0) })
        let named = try #require(byUID["g1"])
        #expect(named.guest == MemoGuest(contributorName: "Anna", passUid: "pass-1"))
        #expect(named.owner == "fabian", "the owner stays the pass's account")
        let nameless = try #require(byUID["g2"])
        #expect(nameless.guest == MemoGuest(contributorName: nil, passUid: "pass-1"))
        #expect(try #require(byUID["own"]).guest == nil, "the owner's own memo read as a guest's")
    }
}
