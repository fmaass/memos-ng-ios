import Foundation
import MemosAPI
import Testing

/// The two shapes memos-ng was observed returning in one response on 2026-08-23. If the transcoder
/// stops accepting either of them, every list request starts failing to decode a 200.
@Suite("RFC3339DateTranscoder")
struct RFC3339DateTranscoderTests {
    private let transcoder = RFC3339DateTranscoder()

    @Test("reads a timestamp with fractional seconds")
    func fractional() throws {
        let date = try transcoder.decode("2026-08-21T20:41:49.443000Z")
        #expect(abs(date.timeIntervalSince1970 - 1_787_344_909.443) < 0.001)
    }

    @Test("reads a timestamp without fractional seconds")
    func whole() throws {
        let date = try transcoder.decode("2026-08-20T20:36:00Z")
        #expect(date.timeIntervalSince1970 == 1_787_258_160)
    }

    @Test("round-trips a date through its own encoding")
    func roundTrip() throws {
        let original = Date(timeIntervalSince1970: 1_787_344_909.443)
        let decoded = try transcoder.decode(try transcoder.encode(original))
        #expect(abs(decoded.timeIntervalSince1970 - original.timeIntervalSince1970) < 1)
    }

    @Test("refuses something that is not a timestamp")
    func rejectsJunk() {
        #expect(throws: (any Error).self) { try transcoder.decode("last Tuesday") }
        #expect(throws: (any Error).self) { try transcoder.decode("") }
    }
}
