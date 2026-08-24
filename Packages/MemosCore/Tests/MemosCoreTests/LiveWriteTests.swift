import Foundation
import MemosAPI
import Testing

@testable import MemosCore

/// The full write loop against a REAL server, through the same stores and generated client the
/// app ships. Skipped unless credentials arrive via the runner environment — this is the
/// acceptance probe for "can the app actually post", not a unit test.
private enum LiveWriteEnvironment {
    static var values: [String: String] { ProcessInfo.processInfo.environment }
    static var configured: Bool {
        values["MEMOS_PAT"] != nil && values["MEMOS_SERVER"] != nil
    }
}

@MainActor
@Suite("Live writes", .enabled(if: LiveWriteEnvironment.configured))
struct LiveWriteTests {

    @Test("create, toggle, edit, pin, visibility and delete survive a real server")
    func fullWriteLoop() async throws {
        let token = try #require(LiveWriteEnvironment.values["MEMOS_PAT"])
        let server = try #require(LiveWriteEnvironment.values["MEMOS_SERVER"])
        let configuration = try #require(ServerConfiguration(serverAddress: server))
        let client = APIClientFactory.make(configuration: configuration) { token }
        let store = TimelineStore()
        let marker = "live-write-probe do-not-keep"

        await store.refresh(using: client, baseURL: configuration.baseURL)
        #expect(store.lastError == nil)

        #expect(
            await store.create(
                content: "\(marker)\n- [ ] probe task",
                visibility: .private,
                using: client,
                baseURL: configuration.baseURL
            )
        )
        let uid = try #require(store.memos.first { $0.content.contains(marker) }?.uid)

        #expect(
            await store.toggleTask(at: 0, in: uid, using: client, baseURL: configuration.baseURL)
        )
        #expect(store.memos.first { $0.uid == uid }?.content.contains("- [x] probe task") == true)

        #expect(
            await store.edit(
                uid: uid,
                content: "\(marker)\n- [x] probe task\nedited",
                using: client,
                baseURL: configuration.baseURL
            )
        )
        #expect(
            await store.setPinned(true, uid: uid, using: client, baseURL: configuration.baseURL)
        )
        #expect(store.memos.first?.uid == uid, "the pinned probe leads the list")
        #expect(
            await store.setPinned(false, uid: uid, using: client, baseURL: configuration.baseURL)
        )
        #expect(
            await store.setVisibility(
                .private, uid: uid, using: client, baseURL: configuration.baseURL
            )
        )
        #expect(await store.delete(uid: uid, using: client))
        #expect(!store.memos.contains { $0.uid == uid })
    }
}
