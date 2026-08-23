import Foundation
import OpenAPIRuntime

/// Reads `date-time` the way RFC 3339 defines it: fractional seconds optional.
///
/// This is not defensive coding. memos-ng returns BOTH shapes in the same response —
/// `2026-08-20T20:36:00Z` next to `2026-08-21T20:41:49.443000Z`, because a timestamp whose
/// microseconds happen to be zero serialises without them — and swift-openapi-runtime's default
/// transcoder accepts only the second-precision form. With the default, every `GET /api/memos`
/// against production fails to decode while still returning 200, which is exactly the kind of
/// failure that reads as "the server is broken".
public struct RFC3339DateTranscoder: DateTranscoder {
    public init() {}

    public func encode(_ date: Date) throws -> String {
        date.formatted(.iso8601.dateTimeSeparator(.standard).timeSeparator(.colon))
    }

    public func decode(_ dateString: String) throws -> Date {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(dateString)
        {
            return date
        }
        if let date = try? Date.ISO8601FormatStyle().parse(dateString) {
            return date
        }
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: [],
                debugDescription: "Expected an RFC 3339 date-time, got '\(dateString)'"
            )
        )
    }
}
