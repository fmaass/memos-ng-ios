import Foundation
import MemosOutbox
import Testing

/// A test bundle built by Xcode has no `Bundle.module`, and Swift Testing has no `XCTestCase` for
/// `Bundle(for:)`, so this token supplies one.
private final class ArtefactBundleToken {}

/// `auto-memo-date.json`, as Swift reads it.
///
/// The artefact is vendored from ONE memos-ng commit beside `openapi.json` (scripts/sync-openapi.sh)
/// and is the same file the server's pytest suite and the SPA's vitest suite are held to. Every case
/// below therefore lives in exactly one place: a rule that changes changes there, and all three
/// implementations go red together. Nothing here may be duplicated as a literal in Swift — a copied
/// vector is a vector that stops being the contract the moment the contract moves.
struct AutoMemoDateArtefact: Sendable {
    struct Vectors: Sendable, Decodable {
        var autoMemoDate: [DateVector]
        var captureOrder: [OrderVector]
        var span: [SpanVector]
        var civilResolution: [CivilVector]
        var videoHeader: [HeaderVector]
        var videoCreationDate: [CreationDateVector]
        var exifStrings: [ExifVector]
    }

    struct Item: Sendable, Decodable {
        var id: String
        var instant: String?
        var civil: String?

        /// The reading a settled item carries. The vectors describe items whose read has FINISHED —
        /// a pending one has no instant at all, which is the composer's business rather than this
        /// arithmetic's.
        var decision: CaptureDecision {
            .settled(
                CaptureReading(
                    instant: instant.flatMap(AutoMemoDateArtefact.instant(_:)),
                    civil: civil,
                    source: instant == nil && civil == nil ? nil : .exif
                ))
        }
    }

    struct Expectation: Sendable, Decodable {
        var instant: String?
        var approximate: Bool
        var span: Int
    }

    struct DateVector: Sendable, Decodable {
        var id: String
        var zone: String
        var items: [Item]
        var expect: Expectation
    }

    struct OrderVector: Sendable, Decodable {
        var id: String
        var zone: String
        var items: [Item]
        var expect: [String]
    }

    struct SpanVector: Sendable, Decodable {
        var id: String
        var zone: String
        var instants: [String]
        var expect: Int
    }

    struct CivilVector: Sendable, Decodable {
        var id: String
        var civil: String
        var zone: String
        var expect: String?
    }

    struct HeaderVector: Sendable, Decodable {
        var id: String
        var seconds: Double?
        var daysFromNow: Double?
        var expect: String?
    }

    struct CreationDateVector: Sendable, Decodable {
        var id: String
        var text: String
        var expect: String?
    }

    struct ExifExpectation: Sendable, Decodable {
        var instant: String?
        var civil: String?
        var source: String?
    }

    struct ExifVector: Sendable, Decodable {
        var id: String
        var datetime: String
        var offset: String?
        var expect: ExifExpectation
    }

    struct Binary: Sendable, Decodable {
        var mime: String
        var note: String?
        var expect: BinaryExpectation
        var sha256: String
        var size: Int
    }

    struct BinaryExpectation: Sendable, Decodable {
        var captureInstant: String?
        var captureCivil: String?
        var captureSource: String?

        enum CodingKeys: String, CodingKey {
            case captureInstant = "capture_instant"
            case captureCivil = "capture_civil"
            case captureSource = "capture_source"
        }
    }

    struct Document: Sendable, Decodable {
        var schema: Int
        var rules: String
        var vectors: Vectors
        var binaries: [String: Binary]
    }

    /// One named binary, so the fixture suite can be parameterised by it.
    struct NamedBinary: Sendable {
        var name: String
        var binary: Binary
        /// The vendored copy, inside the test bundle.
        var url: URL
    }

    /// A function rather than a stored property: `Bundle` is not `Sendable`, and a static one
    /// would be shared state this package builds with complete checking.
    static func bundle() -> Bundle { Bundle(for: ArtefactBundleToken.self) }

    static let document: Document = {
        guard let url = bundle().url(forResource: "auto-memo-date", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Document.self, from: data)
        else {
            fatalError("auto-memo-date.json is not in the test bundle — check project.yml")
        }
        return decoded
    }()

    static let vectors = document.vectors

    /// The binaries the artefact names, each with the vendored file it describes. A name the bundle
    /// has no file for is left here with the URL it should have had, so the suite fails on it
    /// rather than quietly testing eight of nine.
    static let binaries: [NamedBinary] = document.binaries
        .sorted { $0.key < $1.key }
        .map { name, binary in
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let url =
                bundle().url(forResource: stem, withExtension: ext)
                ?? bundle().bundleURL.appending(path: name)
            return NamedBinary(name: name, binary: binary, url: url)
        }

    /// The artefact writes every instant as `YYYY-MM-DDTHH:MM:SSZ`.
    static func instant(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func zone(_ name: String) -> TimeZone {
        guard let zone = TimeZone(identifier: name) else {
            fatalError("the artefact names a zone this platform does not have: \(name)")
        }
        return zone
    }
}

/// A vector's item, as something the ordering function can be handed.
struct ArtefactItem: CaptureCarrying, Sendable {
    var id: String
    var capture: CaptureDecision
}
