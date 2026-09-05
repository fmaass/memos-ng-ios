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
        // The SAME object the media session already holds, not a second cache — two URLCaches over
        // one disk directory is a corruption waiting to happen. Images do not depend on this line
        // any more: `MediaSession` attaches that cache to its own session explicitly, which is the
        // only way to be sure a cache is reached. Installing it here extends it to whatever else
        // in the process still uses the shared session, and only if the shared session had not
        // already been made — which is exactly what the probe below reports.
        URLCache.shared = MediaSession.shared.cache
        let holds = MediaSession.sharedSessionHolds(MediaSession.shared.cache)
        MemosLog.media.info("shared session holds the media cache: \(holds, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.session)
                .environment(appDelegate.outbox)
                // The device's own settings — read by the root view for the appearance it
                // applies, and by the Settings screen for the control that chooses it.
                .environment(AppSettings.shared)
                // The upload preference, over the very store the outbox is listening to, so
                // turning it on sends what is already queued instead of only the next capture.
                .environment(appDelegate.uploadSettings)
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
    // app group, which only a real app has, and the share extension reads what it publishes. The
    // last-known-user file is composed here for the same reason — it is a real container's file,
    // and a test that got one by default would write into it.
    //
    // `lazy` because `onVerified` reaches back into this object: the outbox restart is the one
    // thing the session cannot do for itself, and the moment worth restarting on — a credential
    // going from unconfirmed to confirmed — is a moment only the session knows.
    private(set) lazy var session = SessionStore(
        account: OutboxAccountStore.live(),
        lastKnownUser: LastKnownUserFile.live(),
        // Synchronous, because that is when the transition happens. What it starts is its own
        // task, and that task re-reads the authority before it drains — a confirmation is not a
        // promise that the session still exists by the time a drain gets a turn.
        onVerified: { [weak self] in Task { @MainActor in await self?.drainOnConfirmation() } }
    )
    private(set) var outbox: Outbox?
    /// Built from the outbox's own preference store rather than a second one over the same suite:
    /// the drain acts on the object it was given, and a switch it never hears about is a switch
    /// that only takes effect on the next launch.
    private(set) var uploadSettings: UploadSettings?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let session = session
        // The session is the ONE source of the outbox's authority: who it may upload as and the
        // token it presents come from `credentialGrant()` as a single value, never assembled here
        // out of the keychain and the session separately. The epoch box is what the drain reads
        // synchronously before each request — a hop to the main actor there would be one more
        // instant for an account switch to land in.
        let epoch = session.epoch
        outbox = try? Outbox.live(
            credentials: DeviceOutboxCredentials(epoch: { epoch.current }) {
                await MainActor.run { session.credentialGrant() }
            }
        )
        uploadSettings = outbox.map { UploadSettings(preferences: $0.uploadPreferences) }
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
        // ADOPTION FIRST, and unconditionally. The system woke this process because a chunk
        // FINISHED: its answer carries the server's own byte count, and a wake that attached no
        // handler discards it and re-sends bytes the server already holds. Adoption sends nothing,
        // so it needs no authority.
        await outbox?.adopt()
        // Sending does. A wake whose restore did not settle keeps its captures queued and the next
        // one acquires cleanly.
        guard session.credentialGrant() != nil else { return }
        await outbox?.start()
    }

    /// The drain a confirmation asks for — and NOT a restore.
    ///
    /// This runs a turn after the confirmation that scheduled it, which is long enough for the
    /// session to have ended. Restoring here would put a credential somebody abandoned back on
    /// screen; the only question worth asking is whether there is authority to drain with NOW.
    private func drainOnConfirmation() async {
        guard session.credentialGrant() != nil else { return }
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
