import Foundation
import MemosOutbox
import Testing

@testable import MemosFeatures

/// What happens to the camera's bytes between the encoder and the outbox: nothing.
///
/// That is the whole of MEMNG-114 and the reason `UIImagePickerController` was refused for it — the
/// original is the archive master (ADR-0008), and a picker that hands back a transcoded JPEG for a
/// still the phone took as HEIF has already thrown the master away. So these assertions are about
/// BYTES and about FILE IDENTITY, never about a file extension: a name is the one thing a
/// re-encoding path would still get right.
///
/// An `AVCapturePhoto` cannot be built outside a camera and a simulator has none, so the fixtures
/// stand in for what `fileDataRepresentation()` returns. They are real containers — an ISO
/// base-media `ftyp` box with a HEIF brand, a JPEG SOI marker — and every assertion below is about
/// what the code under test did with them, not about where they came from.
@MainActor
@Suite("Captured media")
struct CapturedMediaTests {
    /// 2026-08-28 14:15:30 UTC, so the stamped name is a fact rather than a moving target.
    static let taken = Date(timeIntervalSince1970: 1_787_926_530)

    static func scratch() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A HEIF file's own first bytes: `ftyp` with the major brand a phone writes, then a payload
    /// that is only there to be compared with itself afterwards.
    static func heif(payload: Int = 4096) -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(contentsOf: Array("ftyp".utf8))
        data.append(contentsOf: Array("heic".utf8))
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append(contentsOf: Array("mif1heic".utf8))
        data.append(Data((0..<payload).map { UInt8($0 % 251) }))
        return data
    }

    static func jpeg(payload: Int = 1024) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        data.append(Data((0..<payload).map { UInt8($0 % 241) }))
        return data
    }

    /// A QuickTime movie's own first bytes, standing in for what `AVCaptureMovieFileOutput` closes.
    static func movie(payload: Int = 8192) -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x14])
        data.append(contentsOf: Array("ftyp".utf8))
        data.append(contentsOf: Array("qt  ".utf8))
        data.append(contentsOf: [0x00, 0x00, 0x02, 0x00])
        data.append(contentsOf: Array("qt  ".utf8))
        data.append(Data((0..<payload).map { UInt8($0 % 253) }))
        return data
    }

    /// Which file on the volume this is. A copy gets a new one; a move keeps it.
    static func inode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )
        return (attributes[.systemFileNumber] as? Int) ?? -1
    }

    // MARK: - stills

    @Test("a photo captured in-app lands in the outbox as HEIF, byte for byte")
    func aCapturedPhotoIsStagedUnchanged() throws {
        let directory = try Self.scratch()
        defer { Self.discard(directory) }
        let bytes = Self.heif()

        let media = try PickedMedia.captured(
            photo: bytes, at: Self.taken, into: directory, timeZone: .gmt
        )

        // The staged file IS what the photo output represented. Not the same size, not the same
        // picture — the same bytes.
        let written = try Data(contentsOf: media.url)
        #expect(
            written == bytes,
            "the staged file is \(written.count) bytes against the camera's \(bytes.count)"
        )
        // And it is still a HEIF container, read out of the file's own head rather than its name:
        // a path that re-encoded would leave the extension exactly as it is.
        #expect(CapturedStill.format(of: written) == .heif)
        #expect(media.url.pathExtension == "heic")
        #expect(media.mime == "image/heic")
        #expect(media.filename == "IMG_20260828-141530.heic")
        #expect(media.lastModified == Self.taken)
    }

    /// The negative control the test above is worth nothing without: the extension and the MIME
    /// type follow what the bytes ARE. A device with no HEVC still encoder answers in JPEG, and
    /// calling that file `.heic` because the settings asked for HEIF is a name that lies.
    @Test("a photo the camera could only produce as JPEG is not called HEIF")
    func aJpegStillIsNotCalledHeif() throws {
        let directory = try Self.scratch()
        defer { Self.discard(directory) }
        let bytes = Self.jpeg()

        let media = try PickedMedia.captured(
            photo: bytes, at: Self.taken, into: directory, timeZone: .gmt
        )

        let written = try Data(contentsOf: media.url)
        #expect(written == bytes)
        #expect(media.url.pathExtension == "jpg")
        #expect(media.mime == "image/jpeg")
        #expect(media.filename == "IMG_20260828-141530.jpg")
    }

    @Test("bytes in no container this app knows are refused rather than re-encoded")
    func unrecognisedStillBytesAreRefused() throws {
        let directory = try Self.scratch()
        defer { Self.discard(directory) }

        #expect(throws: CaptureStagingError.unrecognisedStill) {
            _ = try PickedMedia.captured(
                photo: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
                at: Self.taken,
                into: directory
            )
        }
        // And it refused by writing nothing at all, rather than by writing something and
        // complaining afterwards.
        let left = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        #expect(left.isEmpty, "a refused capture left \(left.map(\.lastPathComponent)) behind")
    }

    @Test("every HEIF brand a phone can write is read as HEIF, and nothing else is")
    func theBrandTableIsRight() {
        for brand in CapturedStill.heifBrands {
            var data = Data([0x00, 0x00, 0x00, 0x18])
            data.append(contentsOf: Array("ftyp".utf8))
            data.append(contentsOf: Array(brand.utf8))
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            #expect(CapturedStill.format(of: data) == .heif, "\(brand) was not read as HEIF")
        }
        // An MPEG-4 file is the same box structure with another brand, and it is not a still.
        var mp4 = Data([0x00, 0x00, 0x00, 0x18])
        mp4.append(contentsOf: Array("ftypmp42".utf8))
        #expect(CapturedStill.format(of: mp4) == nil)
        #expect(CapturedStill.format(of: Data()) == nil)
        #expect(CapturedStill.format(of: Data([0xFF, 0xD8, 0xFF])) == .jpeg)
    }

    // MARK: - recordings

    @Test("a video captured in-app is the recorder's own file, moved rather than rewritten")
    func aCapturedVideoIsMovedNotRewritten() throws {
        let directory = try Self.scratch()
        defer { Self.discard(directory) }
        let recording = directory.appending(path: "recording-\(UUID().uuidString).mov")
        let bytes = Self.movie()
        try bytes.write(to: recording)
        let identity = try Self.inode(of: recording)
        #expect(identity != -1, "the volume gave no file number, so identity proves nothing")

        let media = try PickedMedia.captured(
            movie: recording, at: Self.taken, into: directory, timeZone: .gmt
        )

        let written = try Data(contentsOf: media.url)
        #expect(written == bytes, "the staged recording is \(written.count) of \(bytes.count)")
        // The same file on the volume under a new name. A copy would answer with a new number and
        // anything that re-encoded would have neither the number nor the bytes.
        let moved = try Self.inode(of: media.url)
        #expect(moved == identity, "the staged recording is file \(moved), not \(identity)")
        // And a move leaves nothing behind — a copy would leave a second video in the temporary
        // directory that nothing ever deletes.
        #expect(
            !FileManager.default.fileExists(atPath: recording.path(percentEncoded: false)),
            "the recorder's file is still there, so it was copied"
        )
        #expect(media.mime == "video/quicktime")
        #expect(media.filename == "VID_20260828-141530.mov")
    }

    @Test("a recording that is not on disk is refused")
    func aMissingRecordingIsRefused() throws {
        let directory = try Self.scratch()
        defer { Self.discard(directory) }
        let absent = directory.appending(path: "never-written.mov")

        #expect(throws: CaptureStagingError.recordingMissing("never-written.mov")) {
            _ = try PickedMedia.captured(movie: absent, at: Self.taken, into: directory)
        }
    }

    // MARK: - the outbox

    /// The other half of "no re-encode": the bytes are still the camera's when the OUTBOX has them.
    ///
    /// It runs the real `OutboxRepository.enqueue` — the same call the share extension makes and
    /// the same one `Outbox.enqueue` makes for a photo picked from the library — so this also holds
    /// the promise that a capture takes the existing lane rather than one of its own.
    @Test("a capture reaches the outbox as a job carrying the camera's own bytes")
    func aCaptureReachesTheOutboxUnchanged() async throws {
        let directory = try Self.scratch()
        defer { Self.discard(directory) }
        let stillBytes = Self.heif()
        let movieBytes = Self.movie()
        let recording = directory.appending(path: "recording-\(UUID().uuidString).mov")
        try movieBytes.write(to: recording)

        let still = try PickedMedia.captured(
            photo: stillBytes, at: Self.taken, into: directory, timeZone: .gmt
        )
        let video = try PickedMedia.captured(
            movie: recording, at: Self.taken, into: directory, timeZone: .gmt
        )

        let repository = try OutboxRepository(root: directory.appending(path: "outbox"))
        let job = try await repository.enqueue(
            content: "The tap is still dripping.",
            visibility: nil,
            capturedAt: Self.taken,
            binding: AccountBinding(
                serverBaseURL: URL(string: "https://memos.example.invalid")!,
                ownerSubject: "fabian"
            ),
            sources: [still.stagedSource, video.stagedSource]
        )

        #expect(job.files.count == 2)
        let staged = try #require(job.files.first)
        #expect(staged.mime == "image/heic")
        #expect(staged.filename == "IMG_20260828-141530.heic")
        #expect(staged.byteSize == Int64(stillBytes.count))
        let heldStill = try Data(contentsOf: repository.mediaURL(job: job, file: staged))
        #expect(
            heldStill == stillBytes,
            "the outbox holds \(heldStill.count) bytes of the camera's \(stillBytes.count)"
        )
        #expect(CapturedStill.format(of: heldStill) == .heif)

        let stagedVideo = try #require(job.files.last)
        #expect(stagedVideo.mime == "video/quicktime")
        #expect(stagedVideo.filename == "VID_20260828-141530.mov")
        let heldVideo = try Data(contentsOf: repository.mediaURL(job: job, file: stagedVideo))
        #expect(heldVideo == movieBytes)

        // The job is a job like any other: it is on disk, and the queue reads it back.
        let queued = try await repository.loadJobs()
        #expect(queued.map(\.id) == [job.id])
    }

    @Test("a capture is named for when it was taken, in the time zone it was taken in")
    func aCaptureIsNamedForWhenItWasTaken() throws {
        #expect(
            CaptureName.stamped("IMG", at: Self.taken, extension: "heic", timeZone: .gmt)
                == "IMG_20260828-141530.heic"
        )
        // A local name is the local time, which is the whole reason the stamp is not UTC on a
        // phone: somebody looking for the video they took at a quarter past four.
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        #expect(
            CaptureName.stamped("VID", at: Self.taken, extension: "mov", timeZone: berlin)
                == "VID_20260828-161530.mov"
        )
    }
}
