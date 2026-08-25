import Foundation
import SwiftUI

/// Which appearance the app is painted in — a three-way choice, not a Boolean.
///
/// "System" is a real answer rather than the absence of one: a phone that switches at sunset is
/// what most people want, and a two-state switch cannot express it. It is also the default, which
/// is why an unreadable or unrecognised stored value resolves to it rather than to Light.
public enum AppearancePreference: String, CaseIterable, Sendable, Equatable {
    case system
    case light
    case dark

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// What SwiftUI is told. `nil` is the opinion "follow the device", which is exactly what
    /// `preferredColorScheme(nil)` means — not a missing value.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The settings that belong to this DEVICE, and the whole of them.
///
/// There is exactly one so far, and that is worth saying out loud, because the obvious second
/// candidate is deliberately not here. The default visibility of a new memo belongs to the
/// ACCOUNT: the server stores it, the web app edits it, and `SessionStore.defaultVisibility`
/// already reads it — so it is written back through `SessionStore.setDefaultVisibility`, not kept
/// beside this. Appearance is the opposite kind of fact. It is about this screen in this hand, a
/// second device may reasonably disagree, and the server's own `theme` field is the web app's
/// answer to a different question.
///
/// `UserDefaults` rather than the app group: the share extension is presented by whichever app the
/// person is sharing from and takes its appearance from the system, so publishing this where the
/// extension could read it would buy nothing it could act on.
///
/// Nothing reads this yet outside its own tests. The screen that will offer the choice, and where
/// that screen is reached from, are being drafted before they are built; this is the half that
/// survives whatever the draft decides, so it is written and held to its tests first.
@MainActor
@Observable
public final class AppSettings {
    /// The instance the app composes. Tests build their own over a scratch `UserDefaults`, which
    /// is why the initialiser takes one at all.
    public static let shared = AppSettings()

    /// Namespaced and stable. Renaming it would silently reset everyone's choice, because an
    /// unknown key reads as "System".
    public static let appearanceKey = "settings.appearance"

    private let defaults: UserDefaults

    public private(set) var appearance: AppearancePreference

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appearance = Self.appearance(fromStored: defaults.string(forKey: Self.appearanceKey))
    }

    /// Chooses an appearance and writes it down, in that order and in one place — so there is no
    /// path that changes the screen without also changing what the next launch reads.
    public func select(_ preference: AppearancePreference) {
        appearance = preference
        defaults.set(preference.rawValue, forKey: Self.appearanceKey)
    }

    /// What a stored string means. Absent, empty, or a name written by a version that knew one
    /// this one does not: all "follow the device". A settings key is read on every launch forever,
    /// and the only safe reading of a value it cannot understand is the default.
    public static func appearance(fromStored raw: String?) -> AppearancePreference {
        raw.flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }
}
