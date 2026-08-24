import BackgroundTasks
import MemosCore
import MemosFeatures
import MemosOutbox
import SwiftUI
import UIKit

/// Composition only: the app target owns the session, the media cache and the outbox, and hands
/// them to the feature package. Every decision worth testing lives in a package below this.
@main
struct MemosNGApp: App {
    @UIApplicationDelegateAdaptor(MemosNGAppDelegate.self) private var appDelegate

    init() {
        // Derived media is served through signed URLs with an expiry, so the shared cache is
        // bounded rather than left at whatever the system default happens to be.
        URLCache.shared = MediaCache.makeURLCache()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.session)
                .environment(appDelegate.outbox)
        }
    }
}

/// The app delegate exists for two things the SwiftUI lifecycle cannot express: registering the
/// background-refresh task before launch finishes, and receiving the system's "I relaunched you to
/// finish an upload" callback. Both belong to the outbox, so the outbox is composed here — where a
/// process launched into the background can still reach it.
@MainActor
final class MemosNGAppDelegate: NSObject, UIApplicationDelegate {
    static let refreshIdentifier = "live.discomarder.memosng.outbox-refresh"

    let session = SessionStore()
    private(set) var outbox: Outbox?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let session = session
        outbox = try? Outbox.live(
            credentials: DeviceOutboxCredentials {
                await MainActor.run { session.state.user?.subject }
            }
        )
        // Registration has to happen before launch finishes, whatever else is true of this launch.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: nil
        ) { task in
            MainActor.assumeIsolated { self.run(task) }
        }
        scheduleRefresh()
        return true
    }

    /// The system woke the app because a background upload finished. The completion handler is
    /// stored for the session's delegate to fire once it has drained its events — calling it early
    /// is how an app stops being woken at all.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == OutboxSession.identifier else {
            completionHandler()
            return
        }
        OutboxBackgroundCompletion.shared.store(completionHandler)
        Task { await outbox?.start() }
    }

    private func run(_ task: BGTask) {
        // Re-armed FIRST: a drain that crashes must not also end the chain of future wakes.
        scheduleRefresh()
        let work = Task { @MainActor in
            await outbox?.start()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
