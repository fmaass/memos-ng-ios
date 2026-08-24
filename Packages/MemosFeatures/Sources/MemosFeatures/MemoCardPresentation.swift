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

extension MemoVisibility {
    /// The label the SPA uses for the same choice, so the two apps speak one language.
    public var label: String {
        switch self {
        case .private: "Private"
        case .protected: "Protected"
        case .public: "Public"
        }
    }

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
