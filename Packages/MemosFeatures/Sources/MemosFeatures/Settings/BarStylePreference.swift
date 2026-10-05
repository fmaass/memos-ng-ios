import Foundation
import MemosCore

/// Which main bar the app stands at the foot of its three tabs (MEMNG-690).
enum BarStyle: String, CaseIterable, Identifiable, Sendable {
    /// The system tab bar, centred, minimising itself on scroll: the app as it was.
    case system
    /// The app's own bar, anchored at the leading edge where the system's minimised icon lands,
    /// folding in place to the selected tab's icon (`LeadingMainBar`).
    case leading

    var id: Self { self }

    var label: String {
        switch self {
        case .system: "System"
        case .leading: "Leading"
        }
    }
}

/// The bar style this device uses, remembered between launches.
///
/// Kept the way `LibraryPreferences` keeps the Library's order, and for its reason: it is about how
/// one person reads one screen, the server has no opinion to store, and the only safe reading of a
/// stored value this version does not know is the default — here the system bar, so the switch
/// changes nothing for anybody who never touches it.
@MainActor
@Observable
final class BarStylePreference {
    /// The instance the app composes. A view reads one put in its environment first, which is how a
    /// test hosts the app under a style without touching the device's defaults.
    static let shared = BarStylePreference()

    /// Namespaced and stable: renaming it puts everybody back on the system bar.
    static let styleKey = "dock.barStyle"

    private let defaults: UserDefaults

    private(set) var style: BarStyle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.style = Self.style(fromStored: defaults.string(forKey: Self.styleKey))
    }

    /// Chooses a style and writes it down, in one place, so the bar on screen and what the next
    /// launch reads cannot disagree.
    func select(_ style: BarStyle) {
        self.style = style
        defaults.set(style.rawValue, forKey: Self.styleKey)
    }

    /// What a stored string means: absent, empty or unknown is the system bar.
    static func style(fromStored raw: String?) -> BarStyle {
        raw.flatMap(BarStyle.init(rawValue:)) ?? .system
    }
}
