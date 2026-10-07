import Foundation

/// The signed-in app's surfaces, as a value rather than as literals inside a view body.
///
/// It exists so what the app's main navigation OFFERS is assertable: a tab whose title or glyph is
/// written inline in a view body is a thing no test can read back, and this is the one list that
/// says how many ways into the app there are. It lives in this layer, beside nothing that draws
/// it, so the list is a value the layer above only reads.
nonisolated public enum MainTab: String, CaseIterable, Identifiable, Sendable {
    // Declaration order IS the bar's order, left to right, four tabs: Library, Collections,
    // Timeline, Places (MEMNG-709) — the three the web dock draws (plan page 3929 decision 11)
    // with Collections beside the Library, the other way into what was kept. Which tab the app
    // opens on is not this order's business; the view holding the selection says it, and it
    // stays the Timeline.
    case library
    case collections
    case timeline
    case places

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .timeline: "Timeline"
        case .library: "Library"
        case .collections: "Collections"
        case .places: "Places"
        }
    }

    /// SF Symbols, so the bar looks like every other tab bar on the phone.
    public var symbol: String {
        switch self {
        case .timeline: "list.bullet"
        case .library: "photo.on.rectangle.angled"
        case .collections: "rectangle.stack"
        case .places: "map"
        }
    }
}
