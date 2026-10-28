import Foundation
import MemosOutbox

/// A capture on the timeline before it is a memo: the words, the date, the tags and one tile per
/// file, as the queue holds them (MEMNG-951).
public struct PendingMemo: Sendable, Equatable, Identifiable {
    /// The row's identity. The memo the capture becomes is drawn under the SAME key
    /// (`PendingMemoBoard.key(for:)`), so the swap is one row changing, not one leaving and
    /// another arriving — which is what keeps the list from jumping.
    public var id: String
    /// The capture as the queue last showed it.
    public var job: UploadJob
    /// The memo the server made of it, once the server named one. The card stands until that
    /// memo is on the list, so there is never an instant with neither.
    public var resolvedUID: String?

    /// What the capture now says: an edit taken while the create was in flight is what the person
    /// last left.
    public var caption: String { job.pendingEdit?.content ?? job.content }
    public var date: Date { job.pendingEdit?.capturedAt ?? job.capturedAt }

    /// The tags the server will read out of the caption, each once, in order.
    public var tags: [String] {
        var seen: Set<String> = []
        return serverHashtags(in: caption).filter { seen.insert($0).inserted }
    }

    /// One tile per file the memo will carry, in its order.
    public var tiles: [OutboxFile] {
        guard let edit = job.pendingEdit else { return job.files }
        return edit.fileIDs.compactMap { id in job.files.first { $0.id == id } }
    }
}

/// The pending cards a timeline shows, decided from the queue alone.
///
/// Fenced on removal: a capture a person removed is never shown again by this board — not by a
/// read of the queue that began before the removal and still lists it, and not by the memo a
/// create answer outliving the removal names (`withdraw`). Nothing a later answer carries can
/// undo a decision a person made.
public struct PendingMemoBoard: Sendable, Equatable {
    private var cards: [PendingMemo] = []
    private var withdrawn: Set<UUID> = []
    /// The key each memo that replaced a card keeps for as long as this board lives.
    private var keys: [String: String] = [:]

    public init() {}

    /// The key a capture's card is drawn under.
    public static func key(for jobID: UUID) -> String { "pending:\(jobID.uuidString)" }

    /// The key the memo `uid` is drawn under: its card's, when it was one.
    public func key(for uid: String) -> String { keys[uid] ?? uid }

    /// The queue as last read, and the memos its finished captures became.
    ///
    /// A capture still in the queue is a card, unless a person took it back to the editor (it is
    /// there, not here) or removed it. A card whose capture left the queue stays only when it
    /// became a memo — until that memo is on the list (`visible`, `settle`).
    public mutating func show(_ jobs: [UploadJob], resolved: [UUID: String]) {
        var next: [PendingMemo] = []
        var listed: Set<UUID> = []
        for job in jobs where !withdrawn.contains(job.id) {
            listed.insert(job.id)
            guard job.cancelledAt == nil else { continue }
            let uid = job.resolvedMemoUID ?? resolved[job.id]
            next.append(PendingMemo(id: Self.key(for: job.id), job: job, resolvedUID: uid))
        }
        for card in cards where !listed.contains(card.job.id) {
            guard let uid = card.resolvedUID ?? resolved[card.job.id] else { continue }
            var kept = card
            kept.resolvedUID = uid
            next.append(kept)
        }
        for card in next {
            if let uid = card.resolvedUID { keys[uid] = card.id }
        }
        // Newest capture first, above the server's own memos.
        cards = next.sorted { $0.date > $1.date }
    }

    /// A person removed this capture. From here it is gone for this board.
    public mutating func withdraw(_ jobID: UUID) {
        withdrawn.insert(jobID)
        cards.removeAll { $0.job.id == jobID }
    }

    /// The cards to draw over a list holding the memos `present`: a card whose memo is already on
    /// the list is that memo now.
    public func visible(present: Set<String>) -> [PendingMemo] {
        cards.filter { card in card.resolvedUID.map { !present.contains($0) } ?? true }
    }

    /// The list was read again after these captures became memos: whatever it holds, the cards
    /// have said what they had to say. Without this a memo outside the page that was read would
    /// leave its card standing for ever.
    public mutating func settle() {
        cards.removeAll { $0.resolvedUID != nil }
    }

    /// Another account, or none: nothing on this board was about the one now signed in.
    public mutating func reset() {
        self = PendingMemoBoard()
    }
}
