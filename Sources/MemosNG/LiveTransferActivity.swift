import ActivityKit
import Foundation
import MemosOutbox
import os

/// The one place the app touches ActivityKit. It decides nothing: `TransferActivityDriver` does,
/// from the reads the transfer ledger applied, and this carries each decision out.
///
/// Every read the ledger applies reaches the driver — the reads a background upload's delegate
/// event triggers in a relaunched, locked app included — so the ring moves while the phone is
/// locked.
final class LiveTransferActivity: TransferActivityHosting {
    private static let log = Logger(subsystem: "live.discomarder.memosng", category: "activity")

    /// Composes the driver over the ledger. The ledger holds the hook and the hook holds the
    /// driver, so both live as long as the outbox the ledger belongs to.
    static func follow(_ ledger: TransferLedger?) {
        guard let ledger else { return }
        let driver = TransferActivityDriver(host: LiveTransferActivity())
        ledger.onApplied = { driver.observe($0) }
    }

    /// ActivityKit's update and end are asynchronous; they are carried out in the order the
    /// driver decided them, each after the one before, so an end can never land ahead of the
    /// update it follows.
    private var tail: Task<Void, Never>?

    func start(_ state: TransferActivityState) -> TransferActivityHandle? {
        // Unsupported, switched off by the person, or a simulator without the feature: no
        // activity, and the queue is none the worse for it.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        do {
            let activity = try Activity.request(
                attributes: TransferActivityAttributes(startedAt: Date()),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            return TransferActivityHandle(id: activity.id)
        } catch {
            // Most often the app is not in front, where the system starts no activity. The driver
            // asks again on the next read.
            let reason = error.localizedDescription
            Self.log.info("live activity not started: \(reason, privacy: .public)")
            return nil
        }
    }

    func update(_ activity: TransferActivityHandle, to state: TransferActivityState) {
        let id = activity.id
        enqueue { await Self.update(id: id, to: state) }
    }

    func end(_ activity: TransferActivityHandle, on state: TransferActivityState) {
        let id = activity.id
        enqueue { await Self.end(id: id, on: state) }
    }

    func surviving() -> [SurvivingTransferActivity] {
        Activity<TransferActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map {
                SurvivingTransferActivity(
                    handle: TransferActivityHandle(id: $0.id), startedAt: $0.attributes.startedAt,
                    state: $0.content.state)
            }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    private nonisolated static func running(_ id: String) -> Activity<TransferActivityAttributes>? {
        Activity<TransferActivityAttributes>.activities.first { $0.id == id }
    }

    private nonisolated static func update(id: String, to state: TransferActivityState) async {
        await running(id)?.update(ActivityContent(state: state, staleDate: nil))
    }

    private nonisolated static func end(id: String, on state: TransferActivityState) async {
        await running(id)?.end(
            ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
    }
}
