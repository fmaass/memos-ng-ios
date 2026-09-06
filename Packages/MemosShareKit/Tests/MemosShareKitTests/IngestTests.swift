import CryptoKit
import Foundation
import MemosOutbox
import MemosShareKit
import Testing

/// A count shared by two closures that the commit calls from different places — the licence read
/// and the capture read — so the test can say "signed out by the time the file had been read".
final class ShareReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

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
                binding: { Fixture.binding() },
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
                binding: { Fixture.binding() },
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
                binding: { Fixture.binding() },
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
                binding: { nil },
                expecting: nil,
                into: repository
            )

            #expect(outcome == .notSignedIn)
            #expect(try await repository.loadJobs().isEmpty)
        }
    }

    @Test("a share with neither files nor words leaves the queue untouched")
    func refusesAnEmptyShare() async throws {
        try await withOutbox { repository, _ in
            let outcome = try await ShareIngest.commit(
                items: [.text("   ")],
                note: "  ",
                visibility: nil,
                binding: { Fixture.binding() },
                expecting: Fixture.binding(),
                into: repository
            )

            #expect(outcome == .nothingToPost)
            #expect(try await repository.loadJobs().isEmpty)
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
                binding: { nil },
                expecting: Fixture.binding(),
                into: repository
            )

            #expect(outcome == .notSignedIn)
            #expect(try await repository.loadJobs().isEmpty)
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
                binding: { somebodyElse },
                expecting: Fixture.binding(),
                into: repository
            )

            #expect(outcome == .accountChanged)
            #expect(
                try await repository.loadJobs().isEmpty,
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
                    binding: { Fixture.binding() },
                    expecting: Fixture.binding(),
                    into: repository
                )
            }

            #expect(try await repository.loadJobs().isEmpty)
            let media = root.appending(path: "outbox/media")
            let leftovers =
                (try? FileManager.default.contentsOfDirectory(
                    at: media, includingPropertiesForKeys: nil)) ?? []
            #expect(leftovers.isEmpty, "a manifest is written last, and its media with it")
        }
    }

    /// A share is dated by its photographs, the same way a memo written in the app is.
    ///
    /// It is the same rule and the same functions — this is where the extension gets its Auto date
    /// — so the two clients cannot come to disagree about which photograph a shared memo belongs
    /// to. The read is injected here: what is being held is the RULE (earliest wins, undated last),
    /// not ImageIO.
    @Test("a shared set is dated by its earliest photograph and queued in capture order")
    func theShareTakesTheEarliestCaptureDate() async throws {
        try await withOutbox { repository, root in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let later = try #require(formatter.date(from: "2026-01-01T15:00:00Z"))
            let earlier = try #require(formatter.date(from: "2026-01-01T13:00:00Z"))
            let readings: [String: CaptureReading] = [
                "late.heic": CaptureReading(instant: later, civil: nil, source: .exif),
                "early.heic": CaptureReading(instant: earlier, civil: nil, source: .exif),
            ]
            var files: [SharedItem] = []
            for name in ["late.heic", "undated.heic", "early.heic"] {
                let staged = try Fixture.file(in: root, named: name, bytes: 8)
                files.append(.file(try SharedFile.imported(staged, into: root)))
            }

            let outcome = try await ShareIngest.commit(
                items: files,
                note: "the walk",
                visibility: nil,
                binding: { Fixture.binding() },
                expecting: Fixture.binding(),
                // The moment of sharing, which the photographs are supposed to beat.
                capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
                zone: TimeZone(identifier: "Europe/Berlin") ?? .gmt,
                read: { readings[$0.filename] ?? .empty },
                into: repository
            )

            guard case .enqueued(let id) = outcome else {
                Issue.record("expected the share to be queued, got \(outcome)")
                return
            }
            let job = try #require(await repository.job(id))
            #expect(job.capturedAt == earlier, "the share was dated by the clock, not the photos")
            #expect(
                job.files.map(\.filename) == ["early.heic", "late.heic", "undated.heic"],
                "the queued files are not in capture order")
        }
    }

    /// A sign-out that happens WHILE the files are being read has to stop the write.
    ///
    /// It is the reason the licence is handed over as a read rather than as a value: the capture
    /// reads are an await, a share sheet can stand for hours, and a capture stamped with an account
    /// that has since gone is one the engine holds forever — which looks exactly like a memo that
    /// was lost.
    @Test("an account that changes during the capture reads stops the share")
    func anAccountChangeDuringTheReadsIsRefused() async throws {
        try await withOutbox { repository, root in
            let staged = try Fixture.file(in: root, named: "IMG_0011.heic", bytes: 16)
            let file = try SharedFile.imported(staged, into: root)
            let reads = ShareReadCounter()

            let outcome = try await ShareIngest.commit(
                items: [.file(file)],
                note: "on the beach",
                visibility: nil,
                // Signed in when the sheet posted; signed out by the time the read came back.
                binding: { reads.count == 0 ? Fixture.binding() : nil },
                expecting: Fixture.binding(),
                read: { _ in
                    reads.increment()
                    return .empty
                },
                into: repository
            )

            #expect(outcome == .notSignedIn)
            #expect(
                try await repository.loadJobs().isEmpty,
                "a capture was written for an account that had gone during the reads")
        }
    }

    /// The control: with nothing that carries a date, the moment of sharing is still what the memo
    /// gets — the rule adds a date, it never takes one away.
    @Test("a share of files that say nothing keeps the moment of sharing")
    func undatedFilesKeepTheSharingMoment() async throws {
        try await withOutbox { repository, root in
            let staged = try Fixture.file(in: root, named: "scan.pdf", bytes: 8)
            let shared = Date(timeIntervalSince1970: 1_750_000_000)

            let outcome = try await ShareIngest.commit(
                items: [.file(try SharedFile.imported(staged, into: root))],
                note: "",
                visibility: nil,
                binding: { Fixture.binding() },
                expecting: Fixture.binding(),
                capturedAt: shared,
                read: { _ in .empty },
                into: repository
            )

            guard case .enqueued(let id) = outcome else {
                Issue.record("expected the share to be queued, got \(outcome)")
                return
            }
            #expect(try #require(await repository.job(id)).capturedAt == shared)
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
