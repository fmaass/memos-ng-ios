import Foundation

/// Select mode in the Library's All grid (MEMNG-588; plan page 3929 decisions 6 and 10, the
/// mockup's section 7), as a value: whether it is on, and which files are chosen.
///
/// Here rather than in the screen because every rule it keeps is a rule about a list, not about a
/// drawing — any loaded picture can be chosen, only the signed-in member's own are handed to a
/// delete, a picture that leaves the grid leaves the selection — and a rule that lives in a view
/// body is one no test can hold.
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

    /// Whether the grid shows only the chosen pictures — the toolbar's "Show Selected (N)"
    /// (MEMNG-779). Never true over an empty selection: a grid narrowed to nothing would leave the
    /// button that widens it reading "Select Items", disabled, with nothing to tap.
    public private(set) var narrowed = false

    /// The toolbar's "Show Selected (N)": narrows the grid to the chosen pictures, and the same
    /// press again gives the whole grid back. Refused outside select mode, and with nothing chosen.
    public mutating func toggleNarrowed() {
        guard isActive, narrowed || !uids.isEmpty else { return }
        narrowed.toggle()
    }

    /// The rows the grid draws out of `rows`: all of them, or while narrowed the chosen ones — in
    /// the GRID's order, not the order they were chosen (`rows(in:)` is that), so a narrowed grid
    /// keeps its months and days in place.
    public func visible(in rows: [LibraryRow]) -> [LibraryRow] {
        guard narrowed else { return rows }
        return rows.filter { members.contains($0.id) }
    }

    public func contains(_ uid: String) -> Bool { members.contains(uid) }

    /// The header's Select capsule.
    public mutating func begin() {
        isActive = true
    }

    /// A tile's tap in select mode — any member's picture (MEMNG-684): in a household most of the
    /// grid is the other member's, and Share is as much for theirs as for mine. What a delete may
    /// take out of it is a separate question (`deletable(in:)`).
    public mutating func toggle(_ row: LibraryRow) {
        guard isActive else { return }
        if members.remove(row.id) != nil {
            uids.removeAll { $0 == row.id }
            if uids.isEmpty { narrowed = false }
        } else {
            members.insert(row.id)
            uids.append(row.id)
        }
    }

    /// Empties the selection and stays in select mode.
    public mutating func clear() {
        uids = []
        members = []
        narrowed = false
    }

    /// The header's close button: select mode ends and nothing stays chosen — nor narrowed — so
    /// opening it again starts from nothing, over the whole grid.
    public mutating func close() {
        isActive = false
        clear()
    }

    /// The grid's list changed — a page arrived, a refresh, another filter, a picture deleted,
    /// somebody else signed in. What is no longer in it leaves the selection; a share or a delete
    /// must never act on a file the screen no longer shows. Whose picture it is does not matter
    /// here: a chosen picture of another member's stays chosen while the grid still shows it.
    public mutating func prune(keeping rows: [LibraryRow]) {
        let kept = Set(rows.lazy.map(\.id))
        guard !members.isSubset(of: kept) else { return }
        uids.removeAll { !kept.contains($0) }
        members = Set(uids)
        if uids.isEmpty { narrowed = false }
    }

    /// The chosen rows out of `rows`, in selection order. A uid whose row is not in `rows` is left
    /// out rather than invented.
    public func rows(in rows: [LibraryRow]) -> [LibraryRow] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return uids.compactMap { byID[$0] }
    }

    /// What a delete of this selection may take: the chosen pictures that are the signed-in
    /// member's own, in selection order, and how many chosen pictures are another member's and
    /// stay. The server refuses to delete someone else's file, and a run that met that refusal
    /// would stop there, so another member's picture never reaches the request at all.
    public struct DeleteSet: Sendable, Equatable {
        /// The own pictures' uids, in the order they were chosen. The ONLY uids a delete is sent.
        public let own: [String]
        /// How many chosen pictures belong to another member and are left alone.
        public let othersCount: Int

        public init(own: [String], othersCount: Int) {
            self.own = own
            self.othersCount = othersCount
        }
    }

    /// The selection split by whose picture it is, read from `rows` — the grid's list at the
    /// moment of asking, so `mine` is the server's latest word. A uid whose row is not in `rows`
    /// is in neither part, as `rows(in:)` leaves it out.
    public func deletable(in rows: [LibraryRow]) -> DeleteSet {
        var own: [String] = []
        var othersCount = 0
        for row in self.rows(in: rows) {
            if row.mine {
                own.append(row.id)
            } else {
                othersCount += 1
            }
        }
        return DeleteSet(own: own, othersCount: othersCount)
    }
}
