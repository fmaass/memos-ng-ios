import CryptoKit
import Foundation
import Testing

@testable import MemosOutbox

/// The nine binary fixtures: that they ARE the files the artefact describes, and what this
/// platform's frameworks read out of them.
///
/// The sha256 check is the reason the second half means anything. A fixture is a few hundred bytes
/// of hand-built container, and a vendoring step that truncated one, or a sync that fetched it from
/// a different commit than the rules came from, would leave a suite that still passes on a file
/// nobody intended — so each file is checked against the digest the artefact carries before it is
/// asked what it says.
@Suite("The vendored capture fixtures")
struct CaptureFixtureTests {
    static let binaries = AutoMemoDateArtefact.binaries

    @Test(
        "every fixture the artefact names is vendored, whole",
        arguments: CaptureFixtureTests.binaries)
    func digest(_ named: AutoMemoDateArtefact.NamedBinary) throws {
        let data = try Data(contentsOf: named.url)
        #expect(data.count == named.binary.size, "\(named.name) is not the size the artefact names")
        #expect(
            Self.hex(SHA256.hash(data: data)) == named.binary.sha256,
            "\(named.name) is not the file the artefact describes")
    }

    @Test("a corrupted copy fails the digest check (the positive control)")
    func digestControl() throws {
        let named = try #require(Self.binaries.first { $0.name == "jpeg-offset.jpg" })
        var data = try Data(contentsOf: named.url)
        data[data.count - 1] ^= 0xFF
        #expect(Self.hex(SHA256.hash(data: data)) != named.binary.sha256)
        #expect(data.count == named.binary.size, "the control changed a byte, not the length")
    }

    @Test(
        "the reader answers what the artefact expects",
        arguments: CaptureFixtureTests.binaries)
    func reading(_ named: AutoMemoDateArtefact.NamedBinary) async throws {
        // A fixed "now" so the header's future check is not a race with the clock.
        let now = try #require(AutoMemoDateArtefact.instant("2026-09-06T00:00:00Z"))
        let reading = await CaptureReader.read(
            fileAt: named.url, mime: named.binary.mime, now: now)
        let expected = named.binary.expect.captureInstant.flatMap(AutoMemoDateArtefact.instant(_:))
        #expect(reading.instant == expected, "\(named.name)")
        #expect(reading.civil == named.binary.expect.captureCivil, "\(named.name)")
        #expect(reading.source?.rawValue == named.binary.expect.captureSource, "\(named.name)")
    }

    /// The case that made the reader grow a PNG chunk walk.
    ///
    /// `png-exif-after-idat.png` carries the same `eXIf` chunk as its twin, legally placed after
    /// the image data. ImageIO reports no EXIF dictionary at all for that file (measured on macOS
    /// 26.6 / Swift 6.3.3, 2026-09-06) while the server's reader walks every chunk and finds it —
    /// so the client that could not see the tag grew a second look rather than the artefact losing
    /// the case. Both PNGs answer with the instant the contract names.
    @Test("an eXIf chunk is found wherever the format allows it to be")
    func exifIsFoundBeforeAndAfterTheImageData() async throws {
        let expected = try #require(AutoMemoDateArtefact.instant("2026-01-01T07:15:00Z"))
        for name in ["png-exif.png", "png-exif-after-idat.png"] {
            let named = try #require(Self.binaries.first { $0.name == name })
            let reading = await CaptureReader.read(fileAt: named.url, mime: named.binary.mime)
            #expect(reading.instant == expected, "\(name)")
            #expect(reading.source == .exif, "\(name)")
        }
        // WHICH reader finds which is the divergence the walk exists for, asserted rather than
        // assumed: ImageIO answers for the chunk before the image data and not for the one after.
        let after = try #require(Self.binaries.first { $0.name == "png-exif-after-idat.png" })
        #expect(CaptureReader.imageIOTags(at: after.url) == nil)
        let before = try #require(Self.binaries.first { $0.name == "png-exif.png" })
        #expect(CaptureReader.imageIOTags(at: before.url)?.dateTime == "2026:01:01 13:00:00")
        // And on a PNG with no EXIF at all the walk finds nothing and invents nothing.
        let none = try #require(Self.binaries.first { $0.name == "png-none.png" })
        #expect(PNGExif.dateTags(inFileAt: none.url) == nil)
        #expect(await CaptureReader.read(fileAt: none.url, mime: none.binary.mime) == .empty)
    }

    @Test("the chunk walk reads the date tags and nothing else")
    func theChunkWalkReadsOnlyItsTags() throws {
        let named = try #require(Self.binaries.first { $0.name == "png-exif-after-idat.png" })
        let tags = try #require(PNGExif.dateTags(inFileAt: named.url))
        #expect(tags.dateTime == "2026:01:01 13:00:00")
        #expect(tags.offset == "+05:45")
        // A file that is not a PNG is not walked at all, whatever it contains.
        let jpeg = try #require(Self.binaries.first { $0.name == "jpeg-offset.jpg" })
        #expect(PNGExif.dateTags(inFileAt: jpeg.url) == nil)
    }

    /// The bound, proven with a read that does not come back.
    ///
    /// The composer refuses to post until every item has settled, so an unbounded read would hang
    /// the Post button behind one file. A task group cannot be the mechanism — it waits for its
    /// children at scope exit, and ImageIO does not answer cancellation — so what is asserted here
    /// is the CALLER returning, not the work stopping.
    @Test("a read that never comes back settles as nothing when the deadline passes")
    func theDeadlineBoundsTheRead() async throws {
        let gate = NeverReturns()
        let started = Date()
        let reading = await CaptureReader.withDeadline(.milliseconds(50)) {
            await gate.wait()
            return CaptureReading(instant: Date(), civil: nil, source: .exif)
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(reading == .empty, "a read that never answered was allowed to answer")
        #expect(elapsed < 5, "the deadline did not bound the caller (\(elapsed)s)")
        // Let the abandoned work finish, so the test process is not left with a task in it.
        await gate.release()
    }

    /// A cancelled read has to come back, and quickly. The caller's cancellation reaches neither
    /// the detached work nor the continuation this is parked on by itself — nothing else would ever
    /// resume it — so a composer that goes away while a big video is being read would otherwise
    /// wait out the whole deadline for an answer nobody wants.
    @Test("a cancelled read returns at once, with nothing, and cancels the work")
    func cancellingTheReadReturnsAtOnce() async throws {
        let gate = NeverReturns()
        let sawCancellation = CancellationWitness()
        let started = Date()
        let task = Task {
            await CaptureReader.withDeadline(.seconds(30)) {
                await gate.wait()
                await sawCancellation.record(Task.isCancelled)
                return CaptureReading(instant: Date(), civil: nil, source: .exif)
            }
        }
        // Give the work a turn to start, then take it away.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let reading = await task.value
        let elapsed = Date().timeIntervalSince(started)

        #expect(reading == .empty, "a cancelled read answered with a date anyway")
        #expect(elapsed < 5, "the cancellation waited for the deadline (\(elapsed)s)")
        // And the work itself was cancelled rather than left running to the end of the process.
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await sawCancellation.value == true, "the detached read was not cancelled")
    }

    @Test("the HEIC's date comes from its PRIMARY image, not from item 0")
    func heicPrimaryImage() async throws {
        let named = try #require(Self.binaries.first { $0.name == "heic-offset.heic" })
        let reading = await CaptureReader.read(fileAt: named.url, mime: named.binary.mime)
        let expected = named.binary.expect.captureInstant.flatMap(AutoMemoDateArtefact.instant(_:))
        #expect(reading.instant == expected)
        // The decoy the fixture carries at item 0 is a 2019 date. Reading the wrong index does not
        // fail with an error — it answers confidently with somebody else's year, which is why this
        // is asserted rather than assumed.
        let decoy = AutoMemoDateArtefact.instant("2019-07-07T07:07:07Z")
        #expect(reading.instant != decoy)
    }

    static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Whether the abandoned work saw the cancellation it was sent.
actor CancellationWitness {
    private(set) var value: Bool?
    func record(_ cancelled: Bool) { value = cancelled }
}

/// A read that answers only when the test lets it — which, for the deadline case, is after the
/// deadline has already spoken.
actor NeverReturns {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        released = true
        let waiters = waiting
        waiting = []
        for waiter in waiters { waiter.resume() }
    }
}

/// What a capture looks like on disk, as bytes.
///
/// A manifest is the only thing a capture survives a relaunch as, and the build that reads it is
/// not always the build that wrote it. A round trip cannot see any of that: encoder and decoder
/// agree with each other whatever the keys are called, so a renamed property takes its key along
/// and every manifest already on the device silently loses that field. So the key SET is pinned
/// here against a job with nothing left nil — a key is only missing visibly when there was a value
/// under it — and the fixtures below are written by hand rather than produced by the encoder under
/// test. The genuine pre-edit manifest from build 22 is pinned separately, where the drain that
/// has to survive it is (`AttemptTermTests.swift`).
@Suite("The manifest on disk")
struct ManifestKeyTests {
    /// Every key `UploadJob` writes. Kept as a literal list rather than derived from the type,
    /// because a list derived from the type would be renamed by the same edit it is meant to
    /// catch.
    static let keys: Set<String> = [
        "id", "idempotencyKey", "content", "visibility", "capturedAt", "files", "binding", "state",
        "holdReason", "waitReason", "attemptCount", "nextAttemptAt", "lastError", "cancelledAt",
        "resolvedMemoUID", "editKey", "patchAttempt", "pendingEdit", "editSentAt",
    ]

    static let jobID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let idempotencyKey = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let fileID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// No real capture is held, waiting AND cancelled at once. This one is, because an optional
    /// left nil encodes to no key at all, and a key that is never written cannot be missed.
    static func populated() -> UploadJob {
        UploadJob(
            id: jobID,
            idempotencyKey: idempotencyKey,
            content: "on the beach",
            visibility: "PROTECTED",
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            files: [
                OutboxFile(
                    id: fileID,
                    relativePath: "one.heic",
                    filename: "one.heic",
                    mime: "image/heic",
                    byteSize: 4096,
                    lastModified: Date(timeIntervalSince1970: 1_750_000_001),
                    uploadUID: "u1",
                    bytesConfirmed: 2048,
                    chunkSize: 1024,
                    uploadAttempt: 2,
                    attachmentUID: "a1",
                    stagedForEdit: true)
            ],
            binding: AccountBinding(
                serverBaseURL: URL(string: "https://memos.example/")!, ownerSubject: "owner-1"),
            state: .held,
            holdReason: .serverRefused,
            waitReason: .homeNetwork,
            attemptCount: 3,
            nextAttemptAt: Date(timeIntervalSince1970: 1_750_000_020),
            lastError: "the server said no",
            cancelledAt: Date(timeIntervalSince1970: 1_750_000_080),
            resolvedMemoUID: "memos/42",
            editKey: "44444444-4444-4444-4444-444444444444",
            patchAttempt: 2,
            pendingEdit: PendingEdit(
                content: "on the beach, later",
                visibility: "PUBLIC",
                capturedAt: Date(timeIntervalSince1970: 1_750_000_200),
                fileIDs: [fileID]),
            editUnansweredSince: Date(timeIntervalSince1970: 1_750_000_140))
    }

    /// The same capture as `populated()`, spelled out as a build that never heard of this branch
    /// wrote it. Typed out rather than round-tripped: a fixture the encoder produced would agree
    /// with any rename the encoder also made.
    static let populatedManifest = Data(
        """
        {
          "id" : "11111111-1111-1111-1111-111111111111",
          "idempotencyKey" : "22222222-2222-2222-2222-222222222222",
          "content" : "on the beach",
          "visibility" : "PROTECTED",
          "capturedAt" : "2025-06-15T15:06:40Z",
          "files" : [
            {
              "id" : "33333333-3333-3333-3333-333333333333",
              "relativePath" : "one.heic",
              "filename" : "one.heic",
              "mime" : "image\\/heic",
              "byteSize" : 4096,
              "lastModified" : "2025-06-15T15:06:41Z",
              "uploadUID" : "u1",
              "bytesConfirmed" : 2048,
              "chunkSize" : 1024,
              "uploadAttempt" : 2,
              "attachmentUID" : "a1",
              "stagedForEdit" : true
            }
          ],
          "binding" : {
            "serverBaseURL" : "https:\\/\\/memos.example\\/",
            "ownerSubject" : "owner-1"
          },
          "state" : "held",
          "holdReason" : "serverRefused",
          "waitReason" : "homeNetwork",
          "attemptCount" : 3,
          "nextAttemptAt" : "2025-06-15T15:07:00Z",
          "lastError" : "the server said no",
          "cancelledAt" : "2025-06-15T15:08:00Z",
          "resolvedMemoUID" : "memos\\/42",
          "editKey" : "44444444-4444-4444-4444-444444444444",
          "patchAttempt" : 2,
          "pendingEdit" : {
            "content" : "on the beach, later",
            "visibility" : "PUBLIC",
            "capturedAt" : "2025-06-15T15:10:00Z",
            "fileIDs" : ["33333333-3333-3333-3333-333333333333"]
          },
          "editSentAt" : "2025-06-15T15:09:00Z"
        }
        """.utf8)

    /// The repository's own pair (`OutboxRepository.persist`), because what is being pinned is
    /// what that writes and what the next launch reads.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test("a capture with nothing left nil writes exactly these keys, and no others")
    func theEmittedKeySet() throws {
        let data = try Self.encoder.encode(Self.populated())
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "a manifest is a JSON object")
        #expect(Set(object.keys) == Self.keys)
    }

    @Test("a manifest written before this branch decodes field for field")
    func thePopulatedFixtureDecodes() throws {
        let decoded = try Self.decoder.decode(UploadJob.self, from: Self.populatedManifest)
        // The whole value, so a key that quietly stopped being read cannot hide behind the fields
        // somebody remembered to list here.
        #expect(decoded == Self.populated())
    }

    @Test("a manifest that says when the edit was claimed still hands that instant back")
    func theClaimedInstantIsReadBack() throws {
        let manifest = Data(
            """
            {
              "id" : "11111111-1111-1111-1111-111111111111",
              "idempotencyKey" : "22222222-2222-2222-2222-222222222222",
              "content" : "on the beach",
              "capturedAt" : "2025-06-15T15:06:40Z",
              "files" : [],
              "binding" : {
                "serverBaseURL" : "https:\\/\\/memos.example\\/",
                "ownerSubject" : "owner-1"
              },
              "state" : "creating",
              "attemptCount" : 0,
              "nextAttemptAt" : "2025-06-15T15:06:40Z",
              "editSentAt" : "2025-06-15T15:09:00Z"
            }
            """.utf8)
        let decoded = try Self.decoder.decode(UploadJob.self, from: manifest)
        #expect(decoded.editUnansweredSince == Date(timeIntervalSince1970: 1_750_000_140))
    }
}
