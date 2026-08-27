import Foundation

/// Which memos the archive lets through, as ONE choice.
///
/// The server takes two flags and decides between them itself: `archived_only` wins, and
/// `include_archived` is consulted only when it is off (memos-ng `app/services/memos.py:305-307`).
/// `MemoQuery` keeps both, faithfully, because that is the request. But a person picks one thing,
/// and offering two switches for one thing means one of the four combinations is a setting that
/// silently does nothing — "include the archived ones" with "only the archived ones" already on.
///
/// So this enum IS the exclusion. The flags are derived from it and are not public: the only way
/// to build a filtered query through this seam is to have chosen exactly one of these.
public enum MemoArchiveScope: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// The archived ones left out — what the list has always done, and the default.
    case active
    /// The archived ones alongside the rest.
    case including
    /// Only the archived ones.
    case only

    public var id: String { rawValue }

    var includeArchived: Bool { self == .including }
    var archivedOnly: Bool { self == .only }
}

/// What the search sheet has been narrowed to, as one value.
///
/// It is separate from `MemoQuery` on purpose. `MemoQuery` is the REQUEST — everything the server
/// can be asked, in the shape the server takes it, including the two archive flags and the date
/// anchor the heatmap sets. This is the SHEET: the subset a person picks by hand, in the shape the
/// picking has, which is where two flags become one choice and where a tag list has to be a set
/// rather than a sequence.
///
/// Nothing here is remembered between openings of the sheet (design note §5, Q4) — a filter left
/// over from yesterday is a filter silently hiding memos, which is worse than picking it again.
/// So this is deliberately not `Codable`: there is nowhere for it to be written down.
public struct SearchFilters: Sendable, Equatable {
    /// The tags that must ALL be present, in the order they were chosen. Ordered rather than a
    /// `Set` so the request is stable — a row read twice from the same choices sends the same two
    /// `tag` parameters both times, and a test can say which.
    public private(set) var tags: [String]
    public var visibility: MemoVisibility?
    public var archive: MemoArchiveScope

    public init(
        tags: [String] = [],
        visibility: MemoVisibility? = nil,
        archive: MemoArchiveScope = .active
    ) {
        self.tags = Self.normalised(tags)
        self.visibility = visibility
        self.archive = archive
    }

    /// Nothing picked — the sheet as it opens.
    public static let empty = SearchFilters()

    /// Whether anything has been narrowed at all.
    public var isEmpty: Bool { self == .empty }

    public func contains(_ tag: String) -> Bool {
        tags.contains(Self.normalised([tag]).first ?? "")
    }

    /// The same choice made twice takes the tag off again — a chip is a selection, not a one-way
    /// accumulator, and a row that could only add would be a filter nobody can undo without
    /// closing the sheet.
    public func toggling(_ tag: String) -> SearchFilters {
        guard let name = Self.normalised([tag]).first else { return self }
        var next = self
        if let existing = next.tags.firstIndex(of: name) {
            next.tags.remove(at: existing)
        } else {
            next.tags.append(name)
        }
        return next
    }

    /// These filters, and a term, as the one request they are.
    ///
    /// No anchor: a date is not a filter picked here — it is the heatmap's, and it reaches the
    /// store by its own path. Passing one through would let a stale day ride along with a tag.
    public func query(term: String? = nil) -> MemoQuery {
        MemoQuery(
            term: term,
            tags: tags,
            visibility: visibility,
            includeArchived: archive.includeArchived,
            archivedOnly: archive.archivedOnly
        )
    }

    /// Blank names are dropped and repeats collapse to the first of them.
    ///
    /// The dedupe is the part that matters on the wire: `tag=travel&tag=travel` asks the server
    /// for the memos filed under travel AND travel, which is a request whose second half can only
    /// ever be redundant — and, read by a person debugging a list, a lie about what was chosen.
    private static func normalised(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { raw -> String? in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }
}
