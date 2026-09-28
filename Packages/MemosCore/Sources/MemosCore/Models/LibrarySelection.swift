import Foundation

/// Select mode in the Library's All grid (MEMNG-588; plan page 3929 decisions 6 and 10, the
/// mockup's section 7), as a value: whether it is on, and which files are chosen.
///
/// Here rather than in the screen because every rule it keeps is a rule about a list, not about a
/// drawing — only the signed-in member's own pictures can be chosen, a picture that leaves the
/// grid leaves the selection — and a rule that lives in a view body is one no test can hold.
///
/// The uids are kept in the order they were CHOSEN, not the order the grid shows them: the delete
/// that follows (MEMNG-589) runs through them one at a time in that order, so the first picture
/// tapped is the first one acted on.
public struct LibrarySelection: Sendable, Equatable {
    /// Whether the grid is in select mode, where a tap chooses rather than opens.
    public private(set) var isActive = false
    /// The chosen files, in the order they were chosen.
    public private(set) var uids: [String] = []
    /// The same uids as a set, so a grid of a thousand tiles asking "is this one chosen" does not
    /// walk the list once per tile.
    private var members: Set<String> = []

    public init() {}

    public var count: Int { uids.count }

    public func contains(_ uid: String) -> Bool { members.contains(uid) }

    /// The header's Select capsule.
    public mutating func begin() {
        isActive = true
    }

    /// A tile's tap in select mode. Another member's picture is refused here, not only dimmed on
    /// screen: the delete this selection feeds would be refused by the server for it anyway, and
    /// a selection that could hold it would promise an action that cannot happen.
    public mutating func toggle(_ row: LibraryRow) {
        guard isActive, row.mine else { return }
        if members.remove(row.id) != nil {
            uids.removeAll { $0 == row.id }
        } else {
            members.insert(row.id)
            uids.append(row.id)
        }
    }

    /// Whether every own picture in `rows` is chosen — what the header's toggle shows, and what
    /// makes its next tap a clear. False over a view holding none of mine: there is nothing there
    /// for a tap to clear.
    public func coversAllMine(in rows: [LibraryRow]) -> Bool {
        var sawMine = false
        for row in rows where row.mine {
            sawMine = true
            if !members.contains(row.id) { return false }
        }
        return sawMine
    }

    /// Chooses every own picture in `rows`, after the ones already chosen and in the grid's order.
    public mutating func selectAllMine(in rows: [LibraryRow]) {
        guard isActive else { return }
        for row in rows where row.mine && members.insert(row.id).inserted {
            uids.append(row.id)
        }
    }

    /// Empties the selection and stays in select mode.
    public mutating func clear() {
        uids = []
        members = []
    }

    /// The header's round toggle: select all of mine in view, and the same tap again clears.
    public mutating func toggleAllMine(in rows: [LibraryRow]) {
        guard isActive else { return }
        if coversAllMine(in: rows) {
            clear()
        } else {
            selectAllMine(in: rows)
        }
    }

    /// The header's close button: select mode ends and nothing stays chosen, so opening it again
    /// starts from nothing.
    public mutating func close() {
        isActive = false
        clear()
    }

    /// The grid's list changed — a refresh, another filter, a picture deleted, somebody else signed
    /// in. What is no longer in it, or no longer mine, leaves the selection; a share or a delete
    /// must never act on a file the screen no longer shows.
    public mutating func prune(keeping rows: [LibraryRow]) {
        let kept = Set(rows.lazy.filter(\.mine).map(\.id))
        guard !members.isSubset(of: kept) else { return }
        uids.removeAll { !kept.contains($0) }
        members = Set(uids)
    }

    /// The chosen rows out of `rows`, in selection order. A uid whose row is not in `rows` is left
    /// out rather than invented.
    public func rows(in rows: [LibraryRow]) -> [LibraryRow] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return uids.compactMap { byID[$0] }
    }
}
