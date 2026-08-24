import CryptoKit
import Foundation
import MemosOutbox
import MemosShareKit
import Testing

@Suite("A share on its way into the outbox")
struct IngestTests {
    /// Every test gets its own app-group stand-in, removed afterwards.
    private func withOutbox(
        _ body: (OutboxRepository, URL) async throws -> Void
    ) async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(OutboxRepository(root: root.appending(path: "outbox")), root)
    }

    private func digest(_ url: URL) throws -> SHA256Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }

    @Test("a shared photo is queued whole, byte for byte, bound to the signed-in account")
    func enqueuesASharedPhoto() async throws {
        try await withOutbox { repository, root in
            let staged = try Fixture.file(in: root, named: "IMG_0007.heic", bytes: 4321)
            let file = try SharedFile.imported(staged, into: root)

            let outcome = try await ShareIngest.commit(
                items: [.file(file)],
                note: "on the beach",
                visibility: nil,
                binding: Fixture.binding(),
                expecting: Fixture.binding(),
                capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
                into: repository
            )

            guard case .enqueued(let id) = outcome else {
                Issue.record("expected the share to be queued, got \(outcome)")
                return
            }
            let job = try #require(await repository.job(id))
            #expect(job.content == "on the beach")
            #expect(job.visibility == nil, "no choice made means the account's own default")
            #expect(job.binding == Fixture.binding())
            #expect(job.capturedAt == Date(timeIntervalSince1970: 1_750_000_000))
            #expect(job.files.count == 1)
            let queued = try #require(job.files.first)
            #expect(queued.filename == "IMG_0007.heic")
            #expect(queued.mime == "image/heic")
            #expect(queued.byteSize == 4321)
            #expect(
                try digest(repository.mediaURL(job: job, file: queued)) == digest(staged),
                "the queued copy has to be the original, not a re-encoding of it"
            )
        }
    }

    @Test("a text-only share becomes a memo with no files at all")
    func enqueuesTextOnly() async throws {
        try await withOutbox { repository, _ in
            let outcome = try await ShareIngest.commit(
                items: [.text("An Article"), .link(URL(string: "https://example.invalid/a")!)],
                note: "",
                visibility: nil,
                binding: Fixture.binding(),
                expecting: Fixture.binding(),
                into: repository
            )

            guard case .enqueued(let id) = outcome else {
                Issue.record("expected the share to be queued, got \(outcome)")
                return
            }
            let job = try #require(await repository.job(id))
            #expect(job.files.isEmpty)
            #expect(job.content == "An Article\n\nhttps://example.invalid/a")
            #expect(job.fractionUploaded == 1, "a memo with no bytes is not stuck at 0 %")
        }
    }

    @Test("the chosen visibility reaches the job in the server's own words")
    func carriesTheChosenVisibility() async throws {
        try await withOutbox { repository, _ in
            let outcome = try await ShareIngest.commit(
                items: [.text("just me")],
                note: "",
                visibility: .private,
                binding: Fixture.binding(),
                expecting: Fixture.binding(),
                into: repository
            )
            guard case .enqueued(let id) = outcome else {
                Issue.record("expected the share to be queued, got \(outcome)")
                return
            }
            #expect(await repository.job(id)?.visibility == "PRIVATE")
        }
    }

    @Test("nothing is written while nobody is signed in")
    func refusesWithoutAnAccount() async throws {
        try await withOutbox { repository, root in
            let staged = try Fixture.file(in: root, named: "IMG_0008.heic", bytes: 100)
            let file = try SharedFile.imported(staged, into: root)

            let outcome = try await ShareIngest.commit(
                items: [.file(file)],
                note: "a memo nobody may own",
                visibility: nil,
                binding: nil,
                expecting: nil,
                into: repository
            )

            #expect(outcome == .notSignedIn)
            #expect(await repository.loadJobs().isEmpty)
        }
    }

    @Test("a share with neither files nor words leaves the queue untouched")
    func refusesAnEmptyShare() async throws {
        try await withOutbox { repository, _ in
            let outcome = try await ShareIngest.commit(
                items: [.text("   ")],
                note: "  ",
                visibility: nil,
                binding: Fixture.binding(),
                expecting: Fixture.binding(),
                into: repository
            )

            #expect(outcome == .nothingToPost)
            #expect(await repository.loadJobs().isEmpty)
        }
    }

    @Test("a sign-out between opening the sheet and Post refuses the capture")
    func refusesWhenTheLicenceWentAway() async throws {
        try await withOutbox { repository, root in
            let staged = try Fixture.file(in: root, named: "IMG_0011.heic", bytes: 100)
            let file = try SharedFile.imported(staged, into: root)

            // The sheet was opened while signed in; by the time Post is tapped the licence is
            // gone. The value that decides is the one read AT COMMIT, never the one read at load.
            let outcome = try await ShareIngest.commit(
                items: [.file(file)],
                note: "shared before signing out",
                visibility: nil,
                binding: nil,
                expecting: Fixture.binding(),
                into: repository
            )

            #expect(outcome == .notSignedIn)
            #expect(await repository.loadJobs().isEmpty)
        }
    }

    @Test("an account switch between opening the sheet and Post refuses it too")
    func refusesWhenTheAccountChanged() async throws {
        try await withOutbox { repository, root in
            let staged = try Fixture.file(in: root, named: "IMG_0012.heic", bytes: 100)
            let file = try SharedFile.imported(staged, into: root)
            let somebodyElse = AccountBinding(
                serverBaseURL: Fixture.server, ownerSubject: "someone-else"
            )

            let outcome = try await ShareIngest.commit(
                items: [.file(file)],
                note: "composed for one account",
                visibility: nil,
                binding: somebodyElse,
                expecting: Fixture.binding(),
                into: repository
            )

            #expect(outcome == .accountChanged)
            #expect(
                await repository.loadJobs().isEmpty,
                "posting into the account someone was NOT looking at is not a smaller mistake"
            )
        }
    }

    @Test("a share whose file has gone leaves no half a job behind")
    func leavesNoHalfJob() async throws {
        try await withOutbox { repository, root in
            let staged = try Fixture.file(in: root, named: "IMG_0009.heic", bytes: 100)
            let real = try SharedFile.imported(staged, into: root)
            let vanished = SharedFile(
                url: root.appending(path: "gone.mov"),
                filename: "gone.mov",
                mime: "video/quicktime"
            )

            await #expect(throws: (any Error).self) {
                try await ShareIngest.commit(
                    items: [.file(real), .file(vanished)],
                    note: "half a share",
                    visibility: nil,
                    binding: Fixture.binding(),
                    expecting: Fixture.binding(),
                    into: repository
                )
            }

            #expect(await repository.loadJobs().isEmpty)
            let media = root.appending(path: "outbox/media")
            let leftovers =
                (try? FileManager.default.contentsOfDirectory(
                    at: media, includingPropertiesForKeys: nil)) ?? []
            #expect(leftovers.isEmpty, "a manifest is written last, and its media with it")
        }
    }
}

@Suite("A file taken over from a share provider")
struct SharedFileTests {
    @Test("the copy is the original, and its type comes from its own extension")
    func copiesByteForByte() throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try Fixture.file(in: root, named: "IMG_0010.HEIC", bytes: 2048)
        let destination = root.appending(path: "staged")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let file = try SharedFile.imported(source, into: destination)

        #expect(file.filename == "IMG_0010.HEIC")
        #expect(file.mime == "image/heic")
        #expect(try Data(contentsOf: file.url) == Fixture.content(2048))
        #expect(
            file.url.lastPathComponent == "\(file.id.uuidString).HEIC",
            "a name from outside never decides where a file lands"
        )
        #expect(file.stagedSource.url == file.url)
        #expect(file.stagedSource.filename == "IMG_0010.HEIC")
    }

    @Test("each kind of shared file gets the type the server will see")
    func namesEveryType() {
        #expect(SharedFile.mimeType(forExtension: "heic") == "image/heic")
        #expect(SharedFile.mimeType(forExtension: "JPG") == "image/jpeg")
        #expect(SharedFile.mimeType(forExtension: "png") == "image/png")
        #expect(SharedFile.mimeType(forExtension: "mov") == "video/quicktime")
        #expect(SharedFile.mimeType(forExtension: "mp4") == "video/mp4")
        #expect(SharedFile.mimeType(forExtension: "") == "application/octet-stream")
        #expect(SharedFile.mimeType(forExtension: "notatype") == "application/octet-stream")
    }
}
