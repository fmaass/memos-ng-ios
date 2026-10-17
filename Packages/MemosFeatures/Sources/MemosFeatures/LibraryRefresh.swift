import Foundation
import MemosCore

/// All's two reads — the list, and the day buckets its headings count from — side by side, each
/// going out only under the session that issued them (MEMNG-788).
///
/// A memo action's re-read is asked after the flow has checked that the session it ran under is
/// still the one on screen, but the two reads are child tasks, and a child begins later. So each
/// read takes the current handle at ITS issuance and goes out only when that handle is the issuing
/// generation's: a session that changed after the flow's check and before a child began sends
/// nothing on the new account — and nothing on the old handle either, whose session has ended.
/// Pull-to-refresh comes through here too, under the generation current when the pull began.
@MainActor
enum LibraryRefresh {
    /// One of the two reads, handed the handle and server it goes out on.
    typealias Read = @Sendable @MainActor (SessionHandle, URL) async -> Void
    /// The session as it stands at a read's issuance: its handle and server, or nil.
    typealias Current = @Sendable @MainActor () -> (handle: SessionHandle, baseURL: URL)?

    static func both(
        issuedUnder generation: Int, current: @escaping Current, list: @escaping Read,
        counts: @escaping Read
    ) async {
        async let first: Void = issue(list, issuedUnder: generation, current: current)
        async let second: Void = issue(counts, issuedUnder: generation, current: current)
        _ = await (first, second)
    }

    /// `read`, on the handle current NOW, when it is still `generation`'s.
    static func issue(_ read: Read, issuedUnder generation: Int, current: Current) async {
        guard let now = current(), now.handle.generation == generation else { return }
        await read(now.handle, now.baseURL)
    }
}
