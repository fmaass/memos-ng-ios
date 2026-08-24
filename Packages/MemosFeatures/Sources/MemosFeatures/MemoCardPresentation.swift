import CoreGraphics
import Foundation
import MemosCore

/// How many photos a card shows, and in what arrangement.
///
/// The old row was a horizontal `ScrollView` inside a `NavigationLink`, which is why tapping a
/// photo did nothing: the scroll view swallowed the gesture and the only way into the memo was the
/// chevron at the far right. Laying the photos out instead of scrolling them means the card is one
/// target from edge to edge — tap a photo, open the memo — and the chevron can go.
public enum PhotoLayout: Equatable, Sendable {
    case none
    /// One photo, the width of the card, in its own aspect ratio.
    case solo
    /// Two photos side by side.
    case pair
    /// Three tiles; `overflow` is how many more the memo holds, shown as a count on the last one.
    case strip(overflow: Int)
}

/// The parts of a memo card that are decisions rather than layout.
public enum MemoCardPresentation {
    public static func photoLayout(for count: Int) -> PhotoLayout {
        switch count {
        case ..<1: .none
        case 1: .solo
        case 2: .pair
        default: .strip(overflow: count - 3)
        }
    }

    /// How many tiles a layout actually draws.
    public static func tileCount(for layout: PhotoLayout) -> Int {
        switch layout {
        case .none: 0
        case .solo: 1
        case .pair: 2
        case .strip: 3
        }
    }

    /// The letter in the avatar circle.
    ///
    /// The owner is whatever the server calls the account — a username, sometimes an address. A
    /// circle with a domain in it says nothing, so an address is read up to the `@`, and anything
    /// that yields no letter at all falls back to a symbol rather than an empty circle.
    public static func initial(forOwner owner: String) -> String {
        guard let first = localPart(of: owner).first else { return "?" }
        return String(first).uppercased()
    }

    /// The owner's name as a person would say it: the local part of an address, otherwise the
    /// name as given.
    public static func displayName(forOwner owner: String) -> String {
        let name = localPart(of: owner)
        return name.isEmpty ? "Unknown" : name
    }

    private static func localPart(of owner: String) -> String {
        let trimmed = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return trimmed }
        return String(trimmed[trimmed.startIndex..<at])
    }
}

/// Where a tap on a card goes.
///
/// The card used to be one target from edge to edge, because the alternative at the time was a
/// photo strip that swallowed the tap and left the memo unreachable. The photos have their own
/// destination now — full screen — so the card has two regions, and which one a tap landed in is
/// decided HERE from the tiles' own frames rather than by nesting one button inside another and
/// hoping the inner one wins. A rule a test can state is the only kind that stays true.
public enum MemoCardTap {
    /// A drawn photo tile and the frame it occupies in the card's coordinate space.
    public struct Tile: Equatable, Sendable {
        public let uid: String
        public let frame: CGRect

        public init(uid: String, frame: CGRect) {
            self.uid = uid
            self.frame = frame
        }
    }

    public enum Destination: Equatable, Sendable {
        /// The memo itself — the detail screen.
        case memo
        /// One picture, full screen.
        case attachment(uid: String)
    }

    /// A tap inside a tile opens that picture; everywhere else on the card — the name, the text,
    /// the tags, the gaps between tiles — still opens the memo. Tiles do not overlap, so the first
    /// frame that contains the point is the answer.
    public static func destination(at point: CGPoint, tiles: [Tile]) -> Destination {
        for tile in tiles where tile.frame.contains(point) {
            return .attachment(uid: tile.uid)
        }
        return .memo
    }
}

extension MemoVisibility {
    /// The label the SPA uses for the same choice, so the two apps speak one language.
    public var label: String {
        switch self {
        case .private: "Private"
        case .protected: "Protected"
        case .public: "Public"
        }
    }

    /// The word a pill shows, or `nil` when the glyph carries it alone.
    ///
    /// Public is the household norm: nearly every memo is one, so a pill repeating the word on
    /// every card is a label that never once distinguishes anything — it just adds a box of text
    /// beside every photo. The globe still says it, and the EXCEPTIONS are what deserve words,
    /// because those are the memos where who can see it is news.
    ///
    /// The full `label` is unchanged and is what the menus and the accessibility labels use: this
    /// drops the word from the pill, never from what the app can say.
    public var pillLabel: String? { self == .public ? nil : label }

    /// The glyph beside it. Locked, shared, open — the same three ideas every other app on the
    /// phone uses for the same three states.
    public var symbolName: String {
        switch self {
        case .private: "lock.fill"
        case .protected: "person.2.fill"
        case .public: "globe"
        }
    }
}
