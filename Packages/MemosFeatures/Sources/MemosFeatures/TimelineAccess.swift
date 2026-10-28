import MemosCore
import Observation

/// The app's one timeline store, for the screens outside the Timeline tab that change a memo
/// through it (MEMNG-970).
///
/// The store belongs to the Timeline tab, which builds it (`MemoJump` says why nothing builds a
/// second one), but a viewer opened from the Library, Places or a trip has an Info sheet whose
/// Visibility chip must change the memo on the SAME per-memo line the long press and the edit
/// sheet use — one queue per memo, not a second unserialized PATCH path. The Timeline tab puts its
/// store here; the viewer reads it from the environment. Nil until that tab has built its store,
/// and the chip is inert while it is.
@MainActor
@Observable
final class TimelineAccess {
    var store: TimelineStore?

    init() {}
}
