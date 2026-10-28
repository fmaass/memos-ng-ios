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
        // Before anything reads a preference: `AppSettings.shared` is first read by the body below
        // and `UploadSettings` reads the group's value when the delegate builds it, so the pane's
        // defaults, an earlier build's appearance carried into the group and the version row are
        // all in place first. The group is the pane's one suite; `.standard` is only where earlier
        // builds kept the appearance. The media cache handed over is the one installed above and
        // the one every image fetch goes through: when the pane's Storage switch is on it is
        // cleared here, synchronously, before any view exists to ask for a picture (MEMNG-781).
        SettingsBundleSync.launch(
            from: .main,
            standard: .standard,
            domain: Bundle.main.bundleIdentifier ?? "",
            group: SettingsBundleSync.paneDefaults,
            groupDomain: OutboxDefaults.appGroup,
            cache: MediaSession.shared.cache
        )
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
    // and a test that got one by default would write into it. So is the snapshot store: it is a
    // directory inside the running app's container, and the session is handed the store rather
    // than the writer over it, so the writer can only ever be fenced by this session's own epoch.
    //
    // `lazy` because `onVerified` reaches back into this object: the outbox restart is the one
    // thing the session cannot do for itself, and the moment worth restarting on — a credential
    // going from unconfirmed to confirmed — is a moment only the session knows.
    private(set) lazy var session = SessionStore(
        account: OutboxAccountStore.live(),
        lastKnownUser: LastKnownUserFile.live(),
        snapshots: TimelineSnapshotStore.live(),
        // A route coming back is the one recovery trigger the app has that nobody has to be
        // looking at the screen for.
        routes: NetworkRouteMonitor(),
        // Synchronous, because that is when the transition happens. What it starts is its own
        // task, and that task re-reads the authority before it drains — a confirmation is not a
        // promise that the session still exists by the time a drain gets a turn.
        onVerified: { [weak self] in Task { @MainActor in await self?.drainOnConfirmation() } },
        // A sign-out, revoked or not, or another account signing in over this one: the uploads
        // the system is still carrying hold the old token. Recorded on disk in the call, at the
        // epoch move, so a cancel this process never gets to issue is issued by the next launch;
        // the cancellation itself is handed back for a sign-out to wait on.
        onAccountWithdrawn: { [weak self] epoch in
            guard let outbox = self?.outbox else { return nil }
            outbox.recordWithdrawal(at: epoch)
            return Task { @MainActor in await outbox.finishWithdrawal() }
        }
    )
    private(set) var outbox: Outbox?
    /// Built from the outbox's own preference store rather than a second one over the same suite:
    /// the drain acts on the object it was given, and a switch it never hears about is a switch
    /// that only takes effect on the next launch.
    private(set) var uploadSettings: UploadSettings?
    /// The two lifecycle observers feeding the outbox's scheduling gate, kept for the life of the
    /// process.
    private var lifecycleObservers: [any NSObjectProtocol] = []
    /// MEMNG-538 spike (kill date 2026-11-03): one session per `share.` identifier the system
    /// woke the app for, kept apart from the outbox's two, and the handlers held per wake ticket.
    private var spikeSessions: [String: (session: URLSession, receiver: UploadSpikeReceiver)] = [:]
    private var spikeHandlers: [String: () -> Void] = [:]

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if UploadSpike.isEnabled(SettingsBundleSync.paneDefaults),
            let root = OutboxRepository.appGroupRoot()
        {
            UploadSpikeLog.append(
                "app: didFinishLaunching applicationState=\(application.applicationState.rawValue)",
                root: root)
        }
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
        uploadSettings = outbox.map {
            UploadSettings(preferences: $0.uploadPreferences)
        }
        // ATTACHED AT LAUNCH, ahead of everything. The system can deliver a finished chunk's
        // result the instant this process exists, and a result that finds no handler is discarded
        // with the server's own byte count in it. Nothing here waits on a session: recording what
        // already happened is not a send.
        if let outbox { Task { @MainActor in await outbox.adopt() } }
        // New work starts only while the app is active (decision 9): a wake finishes what the
        // system already holds and sends a finished capture's memo, nothing more. The UIApplication
        // notifications rather than the delegate methods, which a scene-based app is not sent.
        // Both close and open synchronously, on the main queue they are delivered on.
        lifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                // The Settings app may have changed a preference while the app was away; the
                // one activation path reads it back before it opens scheduling and drains.
                MainActor.assumeIsolated {
                    _ = SettingsBundleSync.activate(
                        settings: AppSettings.shared,
                        uploads: self.uploadSettings,
                        outbox: self.outbox,
                        cache: MediaSession.shared.cache,
                        group: SettingsBundleSync.paneDefaults
                    )
                }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    // The outbox closes, and the pane's size row is written as the cache stands
                    // when the app leaves the front.
                    SettingsBundleSync.enteredBackground(
                        outbox: self.outbox, cache: MediaSession.shared.cache,
                        group: SettingsBundleSync.paneDefaults)
                }
            },
        ]
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

    /// The system woke the app because a background upload finished, on either of the outbox's
    /// sessions. The completion handler is held under that session's identifier until the session
    /// has drained its events AND this wake's own work is over — calling it early is how an app
    /// stops being woken at all (`OutboxBackgroundCompletion`).
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Before the outbox is asked: a spike session is not one of its two, and it would answer
        // the system at once.
        if UploadSpike.isSpikeSession(identifier) {
            receiveSpike(identifier, completionHandler: completionHandler)
            return
        }
        let wake = OutboxBackgroundCompletion.shared.beginWake(
            for: identifier, handler: completionHandler
        )
        guard let wake else {
            completionHandler()
            return
        }
        Task { @MainActor in await self.startOutbox(holding: wake) }
    }

    /// MEMNG-538 spike: recreate the extension's session under its identifier, so the system can
    /// deliver what happened to its task, and answer the wake once — when the session has finished
    /// its events, or at the outbox's own fallback deadline, whichever claims first.
    private func receiveSpike(_ identifier: String, completionHandler: @escaping () -> Void) {
        guard let root = OutboxRepository.appGroupRoot() else {
            completionHandler()
            return
        }
        UploadSpikeLog.append("app: handleEventsForBackgroundURLSession \(identifier)", root: root)
        let receiver: UploadSpikeReceiver
        if let existing = spikeSessions[identifier] {
            receiver = existing.receiver
        } else {
            receiver = UploadSpikeReceiver(identifier: identifier, root: root) { ticket in
                Task { @MainActor in
                    self.spikeHandlers.removeValue(forKey: "\(identifier)#\(ticket)")?()
                }
            }
        }
        // Armed and held BEFORE the session exists, so its first event cannot find nothing held.
        let ticket = receiver.claim.arm()
        spikeHandlers["\(identifier)#\(ticket)"] = completionHandler
        if spikeSessions[identifier] == nil {
            let session = URLSession(
                configuration: UploadSpike.backgroundConfiguration(identifier: identifier),
                delegate: receiver, delegateQueue: nil)
            spikeSessions[identifier] = (session, receiver)
        }
        Task {
            try? await Task.sleep(for: OutboxBackgroundCompletion.fallbackDelay)
            receiver.answerOnce(ticket: ticket, reason: "fallback")
        }
    }

    /// `startOutbox`, holding the system's handlers until the outbox is quiescent.
    private func startOutbox(holding wake: WakeWork) async {
        guard let outbox else {
            wake.leave()
            return
        }
        await outbox.wake(holding: wake) { await self.startOutbox() }
    }

    /// Everything a background launch has to do before the queue can move.
    ///
    /// This process may exist only because an upload finished: no window, no `RootView`, and so
    /// nobody to restore the stored credential. The outbox will not send a capture it cannot bind
    /// to an account, so without this a woken app drains nothing at all and the job sits there
    /// looking as though it had been tried.
    private func startOutbox() async {
        // ADOPTION FIRST — before the restore, not after it. The system woke this process because
        // a chunk FINISHED: its answer carries the server's own byte count, and a result that
        // finds no handler is discarded and its bytes sent again. `restore` is a network round
        // trip, so attaching behind it leaves that whole trip as a window. Adoption sends nothing,
        // so it needs no session and waits for none.
        await outbox?.adopt()
        if session.state.user == nil {
            await session.restore()
        }
        // Sending is what needs authority. A wake whose restore did not settle keeps its captures
        // queued and the next one acquires cleanly.
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
        // Entered BEFORE the work starts, so a session's handler held meanwhile waits for it too.
        let wake = OutboxBackgroundCompletion.shared.enterWake()
        // Set BEFORE the work starts. The system may expire a task the moment it hands it over,
        // and whichever of the two arrives first, the system is told exactly once — never twice,
        // and never not at all, which is what gets an app's background time taken away.
        task.expirationHandler = {
            run.expire()
            if run.claimCompletion() { task.setTaskCompleted(success: false) }
        }
        run.attach(
            Task { @MainActor in
                await self.startOutbox(holding: wake)
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
