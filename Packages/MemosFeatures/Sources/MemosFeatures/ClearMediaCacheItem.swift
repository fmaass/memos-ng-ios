import MemosCore
import SwiftUI

/// The Library ⋯ menu's last item: the photos and videos this phone has downloaded, by size, and
/// the one way to empty them now that the Settings screen is gone (chrome trim, 2026-10-10).
///
/// Both halves are emptied (`MediaCacheClearing`), and the size is read again afterwards, so the
/// label the menu shows next is the cache's own answer rather than a number this item assumed.
/// Nothing queued to be posted is reachable from here: the outbox's files are not a derived cache.
struct ClearMediaCacheItem: View {
    @Binding var usage: MediaCacheMaintenance.Usage
    var cache: any DerivedMediaCache = MediaSession.shared.cache
    var decoded: MediaImageStore = MediaImageLoader.store

    static func title(for usage: MediaCacheMaintenance.Usage) -> String {
        "Clear media cache · \(MediaCacheMaintenance.summary(usage))"
    }

    var body: some View {
        Button(Self.title(for: usage), systemImage: "trash") {
            MediaCacheClearing.clearDerived(cache: cache, decoded: decoded)
            usage = MediaCacheClearing.usage(of: cache)
        }
        .disabled(!MediaCacheMaintenance.isClearable(usage))
    }
}
