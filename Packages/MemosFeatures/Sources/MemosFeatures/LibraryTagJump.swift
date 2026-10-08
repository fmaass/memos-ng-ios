import Foundation
import MemosCore

/// A request to show the Library narrowed to one tag, made from a screen that is not the Library.
///
/// The Collections root lists the tags; the grid that can be narrowed to one, and the store that
/// narrows it (`MediaLibraryStore.setTag`), belong to the Library tab. So the request travels, as
/// `MemoJump` does the other way: the root asks, the tab bar switches, and the Library applies the
/// tag to its own store and reads the grid again.
@MainActor
@Observable
final class LibraryTagJump {
    /// The tag somebody asked for, until the Library has applied it. `nil` at rest.
    private(set) var pending: String?

    init() {}

    func request(_ tag: String) {
        pending = tag
    }

    /// Takes the request, once: the first caller gets the tag and every later one nil, so a
    /// request is never applied twice.
    func take() -> String? {
        defer { pending = nil }
        return pending
    }
}

/// Where a tag request goes, decided outside the views that act on it.
enum LibraryTagJumpRouting {
    /// Which tab the app shows: the Library while a tag is pending, else whatever was on screen.
    static func tab(showing current: MainTab, whenOpening tag: String?) -> MainTab {
        tag == nil ? current : .library
    }

    /// Narrows `library` to the pending tag, taking the request. Answers whether the grid has to
    /// be read again — false when nothing was pending or the grid already shows that tag.
    static func apply(_ jump: LibraryTagJump, to library: MediaLibraryStore) -> Bool {
        guard let tag = jump.take(), tag != library.tag else { return false }
        library.setTag(tag)
        return true
    }
}
