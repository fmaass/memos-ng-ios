import MemosCore
import MemosFeatures
import SwiftUI

/// Composition only: the app target owns the session and the media cache and hands them to the
/// feature package. Every decision worth testing lives in MemosCore or MemosFeatures.
@main
struct MemosNGApp: App {
    @State private var session = SessionStore()

    init() {
        // Derived media is served through signed URLs with an expiry, so the shared cache is
        // bounded rather than left at whatever the system default happens to be.
        URLCache.shared = MediaCache.makeURLCache()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}
