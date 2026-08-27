import Foundation
import MemosCore

/// Which end of the library this device opens at, remembered between launches.
///
/// It belongs to the DEVICE for the same reason the appearance does: it is about how one person
/// reads one grid on one screen, a second device may reasonably disagree, and the server has no
/// opinion to store — `GET /api/attachments` takes the direction per request. So it is kept the way
/// `AppSettings` keeps its own single choice: an observable over an injectable `UserDefaults`, a
/// namespaced key, and a reader that answers with the default for anything it does not recognise.
///
/// Separate from `AppSettings` rather than a second property on it, because the two are read in
/// different places at different times — the root view applies the appearance to every screen the
/// app can show, and this is read once, by one grid, when it is built.
@MainActor
@Observable
final class LibraryPreferences {
    /// The instance the app composes. Tests build their own over a scratch `UserDefaults`, which is
    /// why the initialiser takes one at all.
    static let shared = LibraryPreferences()

    /// Namespaced and stable. Renaming it would silently put everybody back to newest-first,
    /// because an unknown key reads as the default.
    static let orderKey = "library.order"

    private let defaults: UserDefaults

    private(set) var order: MediaLibraryOrder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.order = Self.order(fromStored: defaults.string(forKey: Self.orderKey))
    }

    /// Chooses a direction and writes it down, in that order and in one place — so there is no path
    /// that turns the grid round without also changing what the next launch reads.
    func select(_ order: MediaLibraryOrder) {
        self.order = order
        defaults.set(order.rawValue, forKey: Self.orderKey)
    }

    /// What a stored string means. Absent, empty, or a name written by a version that knew one this
    /// one does not: all newest-first. A settings key is read on every launch forever, and the only
    /// safe reading of a value it cannot understand is the default — which here is also what the
    /// server does when the parameter is left off.
    static func order(fromStored raw: String?) -> MediaLibraryOrder {
        raw.flatMap(MediaLibraryOrder.init(rawValue:)) ?? .newestFirst
    }
}
