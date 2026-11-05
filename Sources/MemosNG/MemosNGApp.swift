import BackgroundTasks
import MemosCore
import MemosFeatures
import MemosOutbox
import os
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
                // Guest mode: the trip pass this device holds, if any. Its own store over its own
                // Keychain accounts — the member's session above is never handed any of it.
                .environment(appDelegate.guestSession)
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
    /// The `BGProcessingTask` that copies picked items still in Photos into their captures while
    /// the app is in the background (MEMNG-952). No network needed: it only reads the library.
    static let stagingIdentifier = "live.discomarder.memosng.outbox-staging"

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
        // Beside the licence, and removed with it: the share extension's upload-only credential.
        captureGrants: CaptureGrantStore.live(),
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
    /// The trip pass, kept in its own Keychain accounts under its own epoch, in the same vault the
    /// member session defaults to. `lazy` for the reason `session` is: it is built on the main
    /// actor, the first time something asks.
    private(set) lazy var guestCredentials = GuestCredentialStore(
        credentials: DeviceCredentials.keychain()
    )
    /// Guest mode: redeem, confirm, receipts and leave. A pass becoming this device's — redeemed
    /// or restored — composes the guest queue for it.
    private(set) lazy var guestSession: GuestSessionStore = {
        let guest = GuestSessionStore(
            credentials: self.guestCredentials,
            licence: OutboxAccountStore.guestLive(),
            displayName: UIDevice.current.name
        )
        guest.onActivated = { [weak self] in self?.guestModeActivated() }
        return guest
    }()
    /// The trip pass's queue, apart from the member one: its own directory, background session
    /// and credentials. Composed ONCE per process and never dropped: a background session's
    /// identifier may be held by one session per process, and a second one under the same
    /// identifier would leave the first one's answers undelivered. After a leave or an ended
    /// pass it is inert — its provider has no grant to send under, and what it holds stays held.
    private(set) var guestOutbox: Outbox?
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
    /// Held by wake TICKET, never by identifier: an answer can only ever reach its own wake.
    private var shareHandlers: [Int: () -> Void] = [:]
    private let shareWakes = ShareWakeTickets()
    private static let wakeLog = Logger(subsystem: "live.discomarder.memosng", category: "wake")

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
            },
            shareEventsFinished: { [weak self, shareWakes = self.shareWakes] identifier in
                // Claimed HERE, on the delegate's queue, before the hop to the main actor.
                let won = shareWakes.claimFinished(identifier)
                Task { @MainActor in self?.answerShareWakes(won) }
            }
        )
        uploadSettings = outbox.map {
            UploadSettings(preferences: $0.uploadPreferences)
        }
        // The transfers Live Activity follows every read the ledger applies, the ones a background
        // upload's delegate event triggers included (MEMNG-948).
        LiveTransferActivity.follow(outbox?.transfers)
        // ATTACHED AT LAUNCH, ahead of everything. The system can deliver a finished chunk's
        // result the instant this process exists, and a result that finds no handler is discarded
        // with the server's own byte count in it. Nothing here waits on a session: recording what
        // already happened is not a send.
        // Before the first read of the queue, and before launch finishes: a tap on a transfer
        // notification that launched this process is delivered to the delegate set here.
        attachTransferNotifications(to: outbox)
        if let outbox { Task { @MainActor in await outbox.adopt() } }
        // The guest queue is composed here too, at launch and synchronously, for the reason the
        // member one is: its session has to exist before the system can deliver a guest chunk.
        // The guest licence is the synchronous sign of a standing pass (published on redeem and
        // restore, withdrawn on leave and on an ended pass); the Keychain read is not synchronous.
        if OutboxAccountStore.guestLive()?.currentLicence() != nil {
            composeGuestOutbox()
        }
        // The pass is read back and put to the door; a restored pass composes the queue if the
        // licence above did not.
        let guestSession = guestSession
        Task { @MainActor in await guestSession.restore() }
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
                    self.guestOutbox?.appBecameActive()
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
                    self.guestOutbox?.appEnteredBackground()
                    // The outbox closes, and the pane's size row is written as the cache stands
                    // when the app leaves the front.
                    SettingsBundleSync.enteredBackground(
                        outbox: self.outbox, cache: MediaSession.shared.cache,
                        group: SettingsBundleSync.paneDefaults)
                    self.scheduleStaging()
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
        // Beside it, and on the main queue for the same reason.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.stagingIdentifier,
            using: .main
        ) { task in
            MainActor.assumeIsolated { self.runStaging(task) }
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
        // Which identifier woke the app, for every wake: whether the system wakes a force-quit app
        // for a session the share extension started is exactly what a device run has to record.
        Self.wakeLog.notice(
            "handleEventsForBackgroundURLSession \(identifier, privacy: .public)")
        // A capture's own session, which the share extension started: attached at once — the
        // system delivers its events to the session that carries its identifier — and the system
        // answered when the session says its events are over, or at the fallback deadline.
        if let shareSessions = outbox?.shareSessions, shareSessions.owns(identifier) {
            receiveShare(identifier, sessions: shareSessions, completionHandler: completionHandler)
            return
        }
        // Before the outbox is asked: a spike session is not one of its two, and it would answer
        // the system at once.
        if UploadSpike.isSpikeSession(identifier) {
            receiveSpike(identifier, completionHandler: completionHandler)
            return
        }
        // A guest chunk's wake is the guest queue's to answer: the member outbox knows nothing of
        // that job, and draining it would release the system's handler with the guest answer
        // still undelivered. With no guest queue composed there is nothing to deliver to.
        if identifier == OutboxSession.guestIdentifier {
            // The system relaunched this process for a guest chunk: the queue has work with the
            // system whatever the licence says, so its session is made now to take the answer.
            composeGuestOutbox()
            guard let guestOutbox,
                let wake = OutboxBackgroundCompletion.shared.beginWake(
                    for: identifier, handler: completionHandler)
            else {
                completionHandler()
                return
            }
            Task { @MainActor in await self.startGuestOutbox(holding: wake) }
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

    /// The share session's wake. The held handlers are taken out of the dictionary on the main
    /// actor by whichever of the two answers comes first, so the system is answered exactly once.
    private func receiveShare(
        _ identifier: String, sessions: ShareSessions, completionHandler: @escaping () -> Void
    ) {
        if let root = OutboxRepository.appGroupRoot() {
            UploadSpikeLog.append(
                "app: handleEventsForBackgroundURLSession \(identifier)", root: root)
        }
        let ticket = shareWakes.arm(identifier)
        shareHandlers[ticket] = completionHandler
        sessions.attach(identifier)
        Task { @MainActor in
            await self.outbox?.reattachShareSessions()
            try? await Task.sleep(for: OutboxBackgroundCompletion.fallbackDelay)
            // This wake's own ticket, claimed before anything is answered.
            if self.shareWakes.claim(ticket) { self.answerShareWakes([ticket]) }
        }
    }

    func answerShareWakes(_ tickets: [Int]) {
        for ticket in tickets { shareHandlers.removeValue(forKey: ticket)?() }
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

    /// GUEST HOOK — the one place the guest queue's authority comes from: the guest store, on the
    /// guest epoch. Never the member session's grant.
    private func guestOutboxCredentials() -> any OutboxCredentialsProviding {
        GuestOutboxCredentials(store: guestCredentials)
    }

    /// Composes the guest queue once, attaches what the last run left (sending nothing), and
    /// starts watching it for captures the door turned away.
    @discardableResult
    private func composeGuestOutbox() -> Outbox? {
        if let guestOutbox { return guestOutbox }
        guard let composed = try? Outbox.guestLive(credentials: guestOutboxCredentials()) else {
            return nil
        }
        guestOutbox = composed
        Task { @MainActor in await composed.adopt() }
        watchGuestQueue(composed)
        return composed
    }

    /// A pass became this device's. The queue exists from here on, and — when someone is in front
    /// of the app — it opens and drains now: the launch's activation has already gone by, and a
    /// capture shared to the trip must not wait for the next one.
    private func guestModeActivated() {
        guard let guestOutbox = composeGuestOutbox() else { return }
        if UIApplication.shared.applicationState == .active {
            guestOutbox.appBecameActive()
        }
    }

    /// The guest queue has no refusal channel: a capture the door turned away lands HELD for
    /// credentials, and that is all it says. Every change is handed to the guest session, which
    /// asks the door again under the guest epoch when a hold is new — so the refusal reaches the
    /// guest rule fenced on the epoch that issued the asking, and never the member session.
    private func watchGuestQueue(_ outbox: Outbox) {
        let jobs = withObservationTracking {
            outbox.jobs
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchGuestQueue(outbox) }
        }
        let guestSession = guestSession
        Task { @MainActor in await guestSession.guestQueueChanged(jobs) }
    }

    /// The guest half of a wake, holding the system's handlers until the guest queue is quiescent.
    private func startGuestOutbox(holding wake: WakeWork) async {
        guard let guestOutbox else {
            wake.leave()
            return
        }
        await guestOutbox.wake(holding: wake) { await self.startGuestOutbox() }
    }

    /// What `startOutbox` does for the member, for the pass: attach first, then read the pass back
    /// if this process has not yet, and send only with a grant. Restoring only the credential, not
    /// the session: the door is asked whether the pass stands by the launch's own restore.
    private func startGuestOutbox() async {
        await guestOutbox?.adopt()
        if guestCredentials.current == nil {
            try? await guestCredentials.restore()
        }
        guard guestCredentials.grant() != nil else { return }
        await guestOutbox?.start()
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
        // Sends nothing either: a capture a share session no longer needs is handed back here, so
        // the drain below can finish it — in front. A launch the system made in the background
        // keeps its gate closed, and the capture's offset question waits for the foreground.
        await outbox?.reattachShareSessions()
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
        // The guest queue drains in the same refresh, under its own wake, when it is composed.
        let guestWake = guestOutbox.map { _ in OutboxBackgroundCompletion.shared.enterWake() }
        // Set BEFORE the work starts. The system may expire a task the moment it hands it over,
        // and whichever of the two arrives first, the system is told exactly once — never twice,
        // and never not at all, which is what gets an app's background time taken away.
        task.expirationHandler = {
            run.expire()
            if run.claimCompletion() { task.setTaskCompleted(success: false) }
        }
        run.attach(
            Task { @MainActor in
                async let member: Void = self.startOutbox(holding: wake)
                if let guestWake { await self.startGuestOutbox(holding: guestWake) }
                await member
                if run.claimCompletion() {
                    task.setTaskCompleted(success: !Task.isCancelled)
                }
            }
        )
    }

    /// The staging task's handler: the lane drains every item still in Photos and stops cleanly
    /// on expiry (`StagingLane.run`).
    private func runStaging(_ task: BGTask) {
        guard let outbox, let lane = outbox.staging else {
            task.setTaskCompleted(success: true)
            return
        }
        StagingLane.run(StagingTaskHandle(task), on: lane) { _ in await outbox.refresh() }
    }

    /// Asked for when the app leaves the front with items still in Photos; the system runs it
    /// when it chooses, and a pass in the foreground later finds less or nothing to do.
    private func scheduleStaging() {
        guard let lane = outbox?.staging else { return }
        Task {
            guard await lane.hasWork() else { return }
            let request = BGProcessingTaskRequest(identifier: Self.stagingIdentifier)
            request.requiresNetworkConnectivity = false
            request.requiresExternalPower = false
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// A system task as `StagingLane.run` drives it: the expiry handler and the one completion.
@MainActor
private final class StagingTaskHandle: StagingBackgroundTask {
    private let task: BGTask

    init(_ task: BGTask) { self.task = task }

    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }

    func setTaskCompleted(success: Bool) { task.setTaskCompleted(success: success) }
}
