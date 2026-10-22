import MemosCore
import SwiftUI

/// Where the reader is among the viewer's pages: the ids in the order the pager shows them, and
/// the place of the one on screen (MEMNG-861).
///
/// Built from the pager's RECONCILED list (`MediaViewerPager.visible`), never from
/// `source.pages`: a memo's source is fixed and keeps listing a page this viewer deleted, so an
/// index read from it would keep a place — and the strip a thumbnail — for a file the server no
/// longer has. Computed on every evaluation, like the pages it is read from, so a page the library
/// appended or a delete took away is in it on the frame that shows the change.
struct MediaViewerIndex: Equatable {
    /// The pages' ids, in the pager's order.
    let ids: [MediaPage.ID]
    /// Where the current page is in `ids`; nil while it is in none of them.
    let position: Int?

    init(pages: [MediaPage], current: MediaPage.ID?) {
        let ids = pages.map(\.id)
        self.ids = ids
        position = current.flatMap { ids.firstIndex(of: $0) }
    }
}

/// One row of thumbnails above the viewer's bar: a tap goes to that page, a sideways drag scrubs
/// through them, and the current page sits in the middle, wider than the rest and edged in white.
///
/// The row is laid out by hand rather than in a scroll view. The current thumbnail is wider than
/// the others, so a scroll view's content would change width under the finger every time the
/// current page changed; here the row follows the finger from where the drag began and the page
/// under the middle is the current one (`scrubbed`). Only the thumbnails near the middle are
/// built at all (`window`), so a library of a thousand loaded rows asks for a screenful of thumbs,
/// never the lot — and only ever the thumb tier, never a full-size picture.
///
/// For the library the strip is the LOADED window and grows as more is read: the viewer pages
/// over what is loaded, and a strip claiming more would be a strip of pages the swipe cannot reach.
struct MediaViewerFilmstrip: View {
    /// The pager's reconciled pages, in its order.
    let pages: [MediaPage]
    /// The page on screen.
    let current: MediaPage.ID?
    /// Whether the chrome is drawn: the strip hides with the top row and the bar.
    let shown: Bool
    /// Goes to the page with this id.
    let select: (MediaPage.ID) -> Void

    /// Where a drag began and how far it has gone; nil while no finger is on the strip.
    @State private var scrub: (start: Int, translation: CGFloat)?

    /// A thumbnail's width, the current one's, and the row's height.
    static let thumbWidth: CGFloat = 30
    static let currentWidth: CGFloat = 46
    static let height: CGFloat = 46
    static let spacing: CGFloat = 2
    /// The thumbnails' corner: smaller than any grid tile's, at this size.
    static let corner: CGFloat = 3
    /// How far a finger travels to move the strip by one page.
    static var pitch: CGFloat { thumbWidth + spacing }

    var body: some View {
        let index = MediaViewerIndex(pages: pages, current: current)
        GeometryReader { proxy in
            if let position = index.position, pages.count > 1 {
                row(position: position, width: proxy.size.width)
            }
        }
        .frame(height: Self.height)
        .clipped()
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
    }

    private func row(position: Int, width: CGFloat) -> some View {
        let anchor = scrub?.start ?? position
        let offset = Self.rowOffset(
            width: width, anchor: anchor, translation: scrub?.translation ?? 0)
        let focus =
            scrub.map {
                Self.scrubbed(from: $0.start, translation: $0.translation, count: pages.count)
            } ?? position
        let window = Self.window(count: pages.count, around: focus, width: width)
        let placed = window.map { (index: $0, page: pages[$0]) }
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(placed, id: \.page.id) { item in
                thumbnail(item.page, current: item.index == position)
                    .offset(x: offset + Self.leading(of: item.index, current: position))
            }
        }
        .contentShape(.rect)
        .gesture(drag(from: position))
    }

    private func thumbnail(_ page: MediaPage, current: Bool) -> some View {
        let width = current ? Self.currentWidth : Self.thumbWidth
        return AttachmentThumbnail(
            attachment: page.attachment,
            tier: .thumb,
            slot: AttachmentSlot(aspectRatio: width / Self.height, contentMode: .fill),
            cornerRadius: Self.corner
        )
        .frame(width: width, height: Self.height)
        .overlay {
            if current {
                RoundedRectangle(cornerRadius: Self.corner)
                    .strokeBorder(.white, lineWidth: 2)
            }
        }
        .contentShape(.rect)
        .onTapGesture { select(page.id) }
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: page))
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }

    /// The row follows the finger from where it went down; each page that comes under the middle
    /// becomes the viewer's page, so the pager behind turns with the strip.
    private func drag(from position: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = scrub?.start ?? position
                scrub = (start, value.translation.width)
                let next = Self.scrubbed(
                    from: start, translation: value.translation.width, count: pages.count)
                if pages[next].id != current { select(pages[next].id) }
            }
            .onEnded { _ in
                withAnimation(.snappy) { scrub = nil }
            }
    }

    /// What a thumbnail says: the kind of page it goes to. No position and no count, for the
    /// reason `MediaPage.accessibilityLabel` gives.
    static func label(for page: MediaPage) -> String {
        "\(page.accessibilityLabel) thumbnail"
    }

    /// The page a drag that began on `start` has reached after `translation` points: a drag to the
    /// left moves on to later pages, one page per `pitch`, and never past either end.
    static func scrubbed(from start: Int, translation: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let moved = Int((translation / pitch).rounded())
        return min(max(start - moved, 0), count - 1)
    }

    /// Where thumbnail `index` begins along the row, when `current` is the wide one.
    static func leading(of index: Int, current: Int) -> CGFloat {
        CGFloat(index) * pitch + (index > current ? currentWidth - thumbWidth : 0)
    }

    /// How far the row is moved so that page `anchor`, when it is the wide one, sits in the middle
    /// of `width` — then by however far a finger has dragged it.
    ///
    /// It depends on the anchor and not on the current page or the page count, which is what holds
    /// the current thumbnail still while the library appends pages after it.
    static func rowOffset(width: CGFloat, anchor: Int, translation: CGFloat) -> CGFloat {
        width / 2 - (leading(of: anchor, current: anchor) + currentWidth / 2) + translation
    }

    /// The thumbnails worth building: those that can be on screen around `focus`, and a couple
    /// either side so a drag never uncovers a gap.
    static func window(count: Int, around focus: Int, width: CGFloat) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let reach = Int((width / 2 / pitch).rounded(.up)) + 2
        let lower = max(0, focus - reach)
        let upper = min(count, focus + reach + 1)
        return lower < upper ? lower..<upper : 0..<0
    }
}
