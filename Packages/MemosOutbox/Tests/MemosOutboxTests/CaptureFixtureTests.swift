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
