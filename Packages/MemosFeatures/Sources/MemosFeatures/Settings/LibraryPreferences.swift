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

    /// Whether All is cut into days (MEMNG-818). Namespaced and stable for the order's reason.
    static let groupByDayKey = "library.groupByDay"

    /// Mixed Sizes or Square Grid (MEMNG-821). Namespaced and stable for the order's reason.
    static let tileLayoutKey = "library.tileLayout"

    private let defaults: UserDefaults

    private(set) var order: MediaLibraryOrder

    /// View Options → Group by Day: All under its month headers and day headings, or one flat grid.
    private(set) var groupByDay: Bool

    /// View Options → Mixed Sizes / Square Grid, read by every `LibraryGrid` itself — All and the
    /// trip and collection screens alike — so no screen has to pass it on.
    private(set) var tileLayout: LibraryTileLayout

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.order = Self.order(fromStored: defaults.string(forKey: Self.orderKey))
        self.groupByDay = Self.groupByDay(fromStored: defaults.object(forKey: Self.groupByDayKey))
        self.tileLayout = Self.tileLayout(fromStored: defaults.string(forKey: Self.tileLayoutKey))
    }

    /// Chooses a direction and writes it down, in that order and in one place — so there is no path
    /// that turns the grid round without also changing what the next launch reads.
    func select(_ order: MediaLibraryOrder) {
        self.order = order
        defaults.set(order.rawValue, forKey: Self.orderKey)
    }

    /// Turns Group by Day on or off and writes it down, in one place for the order's reason.
    func select(groupByDay: Bool) {
        self.groupByDay = groupByDay
        defaults.set(groupByDay, forKey: Self.groupByDayKey)
    }

    /// Chooses Mixed Sizes or Square Grid and writes it down, in one place for the order's reason.
    func select(tileLayout: LibraryTileLayout) {
        self.tileLayout = tileLayout
        defaults.set(tileLayout.rawValue, forKey: Self.tileLayoutKey)
    }

    /// What a stored string means: absent, empty or a name this version does not know is Mixed
    /// Sizes, the grid as it was before there was a choice.
    static func tileLayout(fromStored raw: String?) -> LibraryTileLayout {
        raw.flatMap(LibraryTileLayout.init(rawValue:)) ?? .mixed
    }

    /// How the Library's All grid is cut under this choice. Only All reads it: Months and Years
    /// are buckets, and a trip's grid is one block whatever this device prefers.
    var allGrouping: LibraryGridGrouping { groupByDay ? .byDay : .flat }

    /// What a stored value means: only a stored Bool is a choice. Absent, or anything a version
    /// that wrote another kind of value left behind, is the default — grouped by day, decision 13
    /// of plan page 3929, which the toggle adds a choice to and does not move.
    static func groupByDay(fromStored raw: Any?) -> Bool {
        (raw as? Bool) ?? true
    }

    /// What a stored string means. Absent, empty, or a name written by a version that knew one this
    /// one does not: all newest-first. A settings key is read on every launch forever, and the only
    /// safe reading of a value it cannot understand is the default — which here is also what the
    /// server does when the parameter is left off.
    static func order(fromStored raw: String?) -> MediaLibraryOrder {
        raw.flatMap(MediaLibraryOrder.init(rawValue:)) ?? .newestFirst
    }
}
