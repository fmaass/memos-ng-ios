import CoreGraphics
import Foundation
import MemosCore

/// How many photos a card shows, and in what arrangement.
///
/// The old row was a horizontal `ScrollView` inside a `NavigationLink`, which is why tapping a
/// photo did nothing: the scroll view swallowed the gesture and the only way into the memo was the
/// chevron at the far right. Laying the photos out instead of scrolling them means the card is one
/// target from edge to edge — tap a photo, open the memo — and the chevron can go.
///
/// What is laid out changed again with the SPA comparison. A capped three-tile strip with a "+N"
/// badge showed three square crops and a number where a memo held six photos: the wrong shapes, and
/// most of the pictures not on the card at all. The arrangement now is the web app's — ALL of them,
/// each in its own proportions.
public enum PhotoLayout: Equatable, Sendable {
    case none
    /// One photo, the width of the card, in its own aspect ratio, height-capped.
    case solo
    /// Two photos side by side, cropped into one shared square. Two pictures at two different
    /// ratios beside each other read as a mistake rather than as a pair.
    case pair
    /// Three or more: justified rows that fill the card's width exactly (`JustifiedGallery`).
    case justified
}

/// The parts of a memo card that are decisions rather than layout.
public enum MemoCardPresentation {
    public static func photoLayout(for count: Int) -> PhotoLayout {
        switch count {
        case ..<1: .none
        case 1: .solo
        case 2: .pair
        default: .justified
        }
    }

    /// How many tiles a layout actually draws.
    ///
    /// Every photo, now. It stays a function because "nothing is hidden behind a count" is exactly
    /// the property that regressed once already, and a rule a test can state is the only kind that
    /// stays true.
    public static func tileCount(for layout: PhotoLayout, of attachments: Int) -> Int {
        switch layout {
        case .none: 0
        case .solo: min(1, attachments)
        case .pair: min(2, attachments)
        case .justified: max(0, attachments)
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
        /// Whether a direct tap on this tile PLAYS rather than opens the pager. Carried on the
        /// tile rather than looked up at the point of the tap, so the router stays a function of a
        /// point and some rectangles.
        public let plays: Bool

        public init(uid: String, frame: CGRect, plays: Bool = false) {
            self.uid = uid
            self.frame = frame
            self.plays = plays
        }
    }

    public enum Destination: Equatable, Sendable {
        /// The memo itself — the detail screen.
        case memo
        /// One picture, full screen, in the swipeable viewer.
        case attachment(uid: String)
        /// One video, on its own page of that same viewer, already playing — see `plays(_:)`.
        case playback(uid: String)
    }

    /// Whether tapping this attachment should start it playing.
    ///
    /// A tap on a video used to open the viewer, which showed the poster with a play button on it:
    /// the picture of the video, and a second tap needed before anything moved. Tapping a video is
    /// unambiguous — it means play it — so the viewer it opens is already playing when it gets
    /// there (`MediaViewerPlayback`). Both destinations are that same viewer, on the page that was
    /// tapped; what differs is what it does on arrival.
    ///
    /// A video with no streamable rendition is NOT playable: there is nothing to start, so its
    /// page is the poster it has. This is the same `playbackURL` rule the detail view uses, in one
    /// place, so the two surfaces cannot disagree about what a tap on a video does.
    ///
    /// Inside the viewer nothing changes: a video page reached by SWIPING keeps its poster and its
    /// play button, because starting a video somebody swiped past is the surprising thing there.
    public static func plays(_ attachment: MemoAttachment) -> Bool {
        MemoPresentation.playbackURL(for: attachment) != nil
    }

    /// A tap inside a tile opens that picture (or plays that video); everywhere else on the card —
    /// the name, the text, the tags, the gaps between tiles — still opens the memo. Tiles do not
    /// overlap, so the first frame that contains the point is the answer.
    public static func destination(at point: CGPoint, tiles: [Tile]) -> Destination {
        for tile in tiles where tile.frame.contains(point) {
            return tile.plays ? .playback(uid: tile.uid) : .attachment(uid: tile.uid)
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
