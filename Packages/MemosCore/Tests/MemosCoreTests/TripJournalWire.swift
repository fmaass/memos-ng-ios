import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime

/// A trip's journal on a scripted memos-ng, for the suites that delete or remove one of its
/// pictures (MEMNG-793, MEMNG-794): the tag lane and the span lane of the memo listing, the member
/// route as the named pictures less the exclusions the server holds, and every other route as
/// `TripServer` answers it — in Lisbon's July 2026, the window `TripSpanTests` reads.
enum TripJournalWire {
    static let memos = "list_memos_api_memos_get"
    static let tag = "portugal2026"

    /// Lisbon's wall clock in July 2026.
    static func lisbon(_ day: Int, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    /// 10 July 00:00 to 20 July 14:00, Lisbon time.
    static let span = TripSpan(start: lisbon(10, 0), end: lisbon(20, 14), zone: "Europe/Lisbon")

    /// A memo whose pictures, `<uid>-a0`, `<uid>-a1`, …, were taken at `taken`.
    static func memo(_ uid: String, created: Date, taken: [Date]) -> String {
        Stub.memo(
            uid: uid,
            createdAt: created.formatted(.iso8601),
            attachments: taken.enumerated().map { index, date in
                Stub.attachment(
                    uid: "\(uid)-a\(index)", status: "ready",
                    captureInstant: date.formatted(.iso8601))
            }
        )
    }

    /// A server answering `tagged` on the tag lane, `spanned` on the span lane and `named` on the
    /// member route, less what it has excluded from the trip asked for by then.
    static func server(
        tagged: [String] = [], spanned: [String] = [], named: [(String, Date)] = [],
        hold: TripServer.Hold? = nil
    ) -> TripServer {
        let box = LockedValue<TripServer?>(nil)
        let server = TripServer(
            answer: { request, operation in
                if operation == TripWire.members {
                    let trip = (request.path ?? "").split(separator: "/").dropFirst(2).first
                    let row = box.get()?.rows.first { trip == $0.uid[...] }
                    let excluded = Set(row?.exclusions ?? [])
                    let items = named.filter { !excluded.contains($0.0) }.map {
                        TripWire.item($0.0, taken: $0.1)
                    }
                    return Stub.json("[\(items.joined(separator: ","))]")
                }
                guard operation == memos else { return nil }
                let untagged = TripWire.query(request.path ?? "", "tag") == nil
                return Stub.json(Stub.page(untagged ? spanned : tagged, nextCursor: nil))
            }, hold: hold)
        box.set(server)
        return server
    }
}
