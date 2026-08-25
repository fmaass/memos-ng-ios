import Foundation
import Observation

/// What the photo picker has produced, and which selection it belongs to.
///
/// Picking photos, changing your mind and picking again before the first pick has finished
/// loading is ordinary behaviour, and the two loads then overlap. Only one of them may write the
/// attachment list — the pick made LAST — and that is what the stamp decides.
///
/// The stamp is taken SYNCHRONOUSLY, in `selected()`, at the moment the selection lands: it
/// orders SELECTIONS. Taken inside the loading task instead, it would order the tasks' START
/// TIMES, which the scheduler chooses and not the person picking photos — two unstructured tasks
/// started from an `.onChange` have no defined order between them — so a pick made second could
/// be stamped first and then lose to the very pick it was meant to replace.
///
/// It is the same shape as `MediaImageStore`'s generation, for the same reason: the caller reads
/// the fence before it goes away to do slow work, and an answer is refused on arrival once the
/// fence has moved.
@MainActor
@Observable
final class ComposeImports {
    /// The files the current selection produced. The picker hands back its own temporary export;
    /// each one is copied out of it, in order, and the copies are what the outbox takes over.
    private(set) var attachments: [PickedMedia] = []
    /// How many files of the current selection could not be read. Counted, never dropped: see
    /// `ComposeAttachments`.
    private(set) var failed = 0
    /// Whether a selection is still loading.
    private(set) var isImporting = false

    /// The newest selection's stamp. Anything older is stale on arrival.
    private var current = 0

    /// A selection landed. Call this at the call site the selection lands on, before the loading
    /// task is started, and hand the stamp it returns to `load`.
    func selected() -> Int {
        current += 1
        isImporting = true
        return current
    }

    /// Loads one selection's files and writes them — unless a newer selection has landed since
    /// this one was stamped, in which case the whole outcome is dropped, `isImporting` included:
    /// that pick no longer describes what is on the screen, and the newer one is still owed its
    /// spinner.
    ///
    /// - Returns: whether this selection's outcome was the one kept.
    @discardableResult
    func load<Item: Sendable>(
        _ items: [Item],
        stamp: Int,
        using loader: (Item) async -> PickedMedia?
    ) async -> Bool {
        var imported: [PickedMedia] = []
        var failures = 0
        for item in items {
            guard let media = await loader(item) else {
                failures += 1
                continue
            }
            imported.append(media)
        }
        guard stamp == current else { return false }
        attachments = imported
        failed = failures
        isImporting = false
        return true
    }

    /// Drops what is attached AND fences everything in flight, loads that have not begun
    /// included: a pick still on its way when "Remove them" is tapped must never land afterwards,
    /// or the removal undoes itself a second later.
    func clear() {
        current += 1
        attachments = []
        failed = 0
        isImporting = false
    }
}
