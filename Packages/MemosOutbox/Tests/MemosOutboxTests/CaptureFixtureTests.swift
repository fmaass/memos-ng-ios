import CryptoKit
import Foundation
import MemosOutbox
import Testing

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

    /// The one file whose answer this platform does NOT agree with the artefact about, and why.
    ///
    /// `png-exif-after-idat.png` carries the same `eXIf` chunk as `png-exif.png`, legally placed
    /// after the image data. Pillow (the server's reader) walks every chunk and finds it; Apple's
    /// ImageIO stops at what its header parse collected and reports no EXIF dictionary at all
    /// (measured on macOS 26.6 / Swift 6.3.3, 2026-09-06, and again by this suite on every run).
    /// The rules are implemented as written — the primary image's EXIF dictionary, three tags — and
    /// nothing here goes looking through PNG chunks to make one fixture pass, because a reader bent
    /// to satisfy a fixture is a reader that no longer says what the platform does. The divergence
    /// is asserted explicitly below instead, so the day ImageIO starts reading it, this suite says
    /// so rather than silently agreeing.
    static let divergingOnThisPlatform: Set<String> = ["png-exif-after-idat.png"]

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
        arguments: CaptureFixtureTests.binaries.filter {
            !CaptureFixtureTests.divergingOnThisPlatform.contains($0.name)
        }
    )
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

    @Test("ImageIO does not see an eXIf chunk placed after the image data")
    func exifAfterImageDataIsInvisibleHere() async throws {
        let named = try #require(Self.binaries.first { $0.name == "png-exif-after-idat.png" })
        let reading = await CaptureReader.read(fileAt: named.url, mime: named.binary.mime)
        #expect(
            reading == .empty,
            """
            ImageIO now reads an eXIf chunk after IDAT. That is the artefact's expectation \
            (\(named.binary.expect.captureInstant ?? "nil")) and this exception should be retired.
            """)
        // Its twin, the identical chunk placed BEFORE the image data, is the control: it proves
        // the file's EXIF is readable at all and that only the placement is at issue.
        let twin = try #require(Self.binaries.first { $0.name == "png-exif.png" })
        let control = await CaptureReader.read(fileAt: twin.url, mime: twin.binary.mime)
        #expect(control.instant != nil)
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
