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

    /// The page a drag is anchored on and how far it has gone; nil while no finger is on the strip.
    @State private var scrub: FilmstripScrub?

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
        let ids = pages.map(\.id)
        // Until the next drag update rebases it, a scrub whose anchor has left the pages is drawn
        // as no scrub at all: the current page in the middle, where the finger is.
        let held = scrub.flatMap { scrub in scrub.start(in: ids).map { (scrub, $0) } }
        let anchor = held?.1 ?? position
        let offset = Self.rowOffset(
            width: width, anchor: anchor, translation: held?.0.travelled ?? 0)
        let focus = held.flatMap { $0.0.reached(in: ids) } ?? position
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
                let step = Self.dragged(
                    scrub, to: value.translation.width, over: pages.map(\.id), current: position)
                scrub = step.scrub
                if pages[step.reached].id != current { select(pages[step.reached].id) }
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

    /// One update of a drag over the pages as they stand NOW: the scrub it leaves, and the index
    /// of the page under the middle.
    ///
    /// The scrub is anchored on a page id, never an index (MEMNG-901). A delete that lands while
    /// the finger is down takes a page out from under the strip; an index saved when the drag began
    /// would then name the page after the one it meant, and the next update would jump. Looked up
    /// by id, the anchor moves with its page. When the anchor itself is what went, the scrub starts
    /// again from the page on screen, at the finger's present travel, so nothing jumps either.
    static func dragged(
        _ scrub: FilmstripScrub?, to translation: CGFloat, over ids: [MediaPage.ID], current: Int
    ) -> (scrub: FilmstripScrub, reached: Int) {
        if var scrub, scrub.start(in: ids) != nil {
            scrub.translation = translation
            return (scrub, scrub.reached(in: ids) ?? current)
        }
        let fresh = FilmstripScrub(
            anchor: ids[current], origin: scrub == nil ? 0 : translation, translation: translation)
        return (fresh, fresh.reached(in: ids) ?? current)
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

/// A drag on the filmstrip: the page it is anchored on, by id, and how far the finger has gone.
struct FilmstripScrub: Equatable {
    /// The page that sat in the middle when the anchor was taken.
    let anchor: MediaPage.ID
    /// The drag's translation when the anchor was taken: zero for a fresh drag, the travel so far
    /// for one that had to start again from another page.
    let origin: CGFloat
    /// The drag's translation now.
    var translation: CGFloat

    /// How far the row has moved since the anchor was taken.
    var travelled: CGFloat { translation - origin }

    /// Where the anchor stands among `ids`; nil once it has left them.
    func start(in ids: [MediaPage.ID]) -> Int? { ids.firstIndex(of: anchor) }

    /// The page the drag has reached over `ids`; nil once the anchor has left them.
    func reached(in ids: [MediaPage.ID]) -> Int? {
        start(in: ids).map {
            MediaViewerFilmstrip.scrubbed(from: $0, translation: travelled, count: ids.count)
        }
    }
}
