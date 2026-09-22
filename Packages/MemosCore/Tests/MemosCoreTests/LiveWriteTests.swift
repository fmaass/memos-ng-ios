import Foundation
import MemosAPI
import MemosOutbox
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

/// 1x1 black and 1x1 white as PNG, embedded so the probe needs no fixture file.
///
/// Two distinct pixels, not just two names: the server stores the bytes, and the point of this
/// probe is that the picture kept is the one that was NAMED, so two byte-identical files would
/// let a wrong answer look right.
private let livePNGBlack =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR42mNgYGAAAAAEAAHI6uv5AAAAAElFTkSuQmCC"
private let livePNGWhite =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR42mP4//8/AAX+Av4zEpUUAAAAAElFTkSuQmCC"

private struct LivePNGUndecodable: Error {}

/// One of those PNGs written where the test can hand its URL to `attaching:`.
private func livePNG(
    named name: String,
    base64: String,
    in directory: URL
) throws -> StagedSource {
    guard let bytes = Data(base64Encoded: base64) else { throw LivePNGUndecodable() }
    let url = directory.appending(path: name)
    try bytes.write(to: url)
    return StagedSource(url: url, filename: name, mime: "image/png")
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

        await store.refresh(using: client.handle, baseURL: configuration.baseURL)
        #expect(store.lastError == nil)

        #expect(
            await store.create(
                content: "\(marker)\n- [ ] probe task",
                visibility: .private,
                using: client.handle,
                baseURL: configuration.baseURL
            )
        )
        let uid = try #require(store.memos.first { $0.content.contains(marker) }?.uid)

        #expect(
            await store.toggleTask(
                at: 0,
                in: uid,
                using: client.handle,
                baseURL: configuration.baseURL
            )
        )
        #expect(store.memos.first { $0.uid == uid }?.content.contains("- [x] probe task") == true)

        #expect(
            await store.edit(
                uid: uid,
                content: "\(marker)\n- [x] probe task\nedited",
                using: client.handle,
                baseURL: configuration.baseURL
            ).isSaved
        )
        #expect(
            await store.setPinned(
                true,
                uid: uid,
                using: client.handle,
                baseURL: configuration.baseURL
            )
        )
        #expect(store.memos.first?.uid == uid, "the pinned probe leads the list")
        #expect(
            await store.setPinned(
                false,
                uid: uid,
                using: client.handle,
                baseURL: configuration.baseURL
            )
        )
        #expect(
            await store.setVisibility(
                .private, uid: uid, using: client.handle, baseURL: configuration.baseURL
            )
        )
        #expect(await store.delete(uid: uid, using: client.handle))
        #expect(!store.memos.contains { $0.uid == uid })
    }

    /// The new contract, against the real server: `attachment_uids` REPLACES a memo's picture
    /// list, so a list that names only the second attachment must leave the first one off the
    /// memo. A unit test can only prove what the client SENT; this proves what the server kept.
    ///
    /// The memo is deliberately left behind — the database read-back that closes this check is
    /// somebody else's, and a probe that deleted its own evidence could not be read back.
    @Test("a picture taken off the list is gone from a real server")
    func removingAPictureFromTheListLeavesOnlyTheNamedOne() async throws {
        let token = try #require(LiveWriteEnvironment.values["MEMOS_PAT"])
        let server = try #require(LiveWriteEnvironment.values["MEMOS_SERVER"])
        let configuration = try #require(ServerConfiguration(serverAddress: server))
        let client = APIClientFactory.make(configuration: configuration) { token }
        let store = TimelineStore()
        let marker = "live-picture-probe do-not-keep b23-p4"

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "live-picture-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try livePNG(named: "first.png", base64: livePNGBlack, in: directory)
        let second = try livePNG(named: "second.png", base64: livePNGWhite, in: directory)

        await store.refresh(using: client.handle, baseURL: configuration.baseURL)
        #expect(store.lastError == nil)

        #expect(
            await store.create(
                content: marker,
                visibility: .private,
                using: client.handle,
                baseURL: configuration.baseURL
            )
        )
        let uid = try #require(store.memos.first { $0.content.contains(marker) }?.uid)

        #expect(
            await store.edit(
                uid: uid,
                content: marker,
                attaching: [first, second],
                listing: nil,
                using: client.handle,
                baseURL: configuration.baseURL
            ).isSaved
        )
        await store.refresh(using: client.handle, baseURL: configuration.baseURL)
        let attached = try #require(store.memos.first { $0.uid == uid }).attachments
        try #require(attached.count == 2)
        let firstUID = attached[0].uid
        let secondUID = attached[1].uid
        try #require(firstUID != secondUID)

        #expect(
            await store.edit(
                uid: uid,
                content: marker,
                attaching: [],
                listing: [.kept(secondUID)],
                using: client.handle,
                baseURL: configuration.baseURL
            ).isSaved
        )
        await store.refresh(using: client.handle, baseURL: configuration.baseURL)
        let remaining = try #require(store.memos.first { $0.uid == uid }).attachments
        #expect(remaining.count == 1)
        #expect(remaining.first?.uid == secondUID)
        #expect(!remaining.contains { $0.uid == firstUID })

        // The identifiers the database read-back needs, on the one surface that leaves this
        // process: the xcodebuild log.
        print("LIVE-PROBE memo=\(uid) kept=\(secondUID) removed=\(firstUID)")
    }
}
