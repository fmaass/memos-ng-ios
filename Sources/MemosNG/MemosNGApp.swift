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

    // The account store is composed here, not defaulted inside the session: it writes into the
    // app group, which only a real app has, and the share extension reads what it publishes.
    let session = SessionStore(account: OutboxAccountStore.live())
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
        // Registration has to happen before launch finishes, whatever else is true of this
        // launch. The queue is named EXPLICITLY: with `nil` the system delivers the launch handler
        // on a background queue, where assuming main-actor isolation is a trap rather than a hop —
        // and a `BGTask` is not `Sendable`, so hopping with a Task would mean carrying it across
        // an isolation boundary unsafely. Asking for the main queue makes the assumption true.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: .main
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
        Task { @MainActor in await self.startOutbox() }
    }

    /// Everything a background launch has to do before the queue can move.
    ///
    /// This process may exist only because an upload finished: no window, no `RootView`, and so
    /// nobody to restore the stored credential. The outbox will not send a capture it cannot bind
    /// to an account, so without this a woken app drains nothing at all and the job sits there
    /// looking as though it had been tried.
    private func startOutbox() async {
        if session.state.user == nil {
            await session.restore()
        }
        await outbox?.start()
    }

    private func run(_ task: BGTask) {
        // Re-armed FIRST: a drain that crashes must not also end the chain of future wakes.
        scheduleRefresh()

        let run = BackgroundRun()
        // Set BEFORE the work starts. The system may expire a task the moment it hands it over,
        // and whichever of the two arrives first, the system is told exactly once — never twice,
        // and never not at all, which is what gets an app's background time taken away.
        task.expirationHandler = {
            run.expire()
            if run.claimCompletion() { task.setTaskCompleted(success: false) }
        }
        run.attach(
            Task { @MainActor in
                await self.startOutbox()
                if run.claimCompletion() {
                    task.setTaskCompleted(success: !Task.isCancelled)
                }
            }
        )
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
