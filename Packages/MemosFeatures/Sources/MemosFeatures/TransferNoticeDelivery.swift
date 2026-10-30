import Foundation
import MemosCore
import MemosOutbox
import UserNotifications

/// The system's notification center, as the poster needs it.
@MainActor
public protocol TransferNoticeCenter {
    func requestAuthorization() async -> Bool
    func add(_ notice: TransferNotice) async
}

/// `UNUserNotificationCenter`, behind the seam.
public struct SystemNoticeCenter: TransferNoticeCenter {
    public init() {}

    public func requestAuthorization() async -> Bool {
        // A refusal is the person's answer; there is nothing to do with it but not post.
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert, .sound,
        ])) ?? false
    }

    public func add(_ notice: TransferNotice) async {
        try? await UNUserNotificationCenter.current().add(Self.request(for: notice))
    }

    static func request(for notice: TransferNotice) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.userInfo = notice.route.userInfo
        content.threadIdentifier = "transfers"
        return UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
    }
}

/// Posts notices in order, asking for permission once — at the first post, never at launch.
@MainActor
public final class TransferNoticePoster {
    private let center: any TransferNoticeCenter
    private var asked = false
    /// The delivery in flight, which the next one waits behind so a post never overtakes the
    /// permission question.
    private(set) var tail: Task<Void, Never>?

    public init(center: any TransferNoticeCenter = SystemNoticeCenter()) {
        self.center = center
    }

    public func post(_ notices: [TransferNotice]) {
        guard !notices.isEmpty else { return }
        let ask = !asked
        asked = true
        let previous = tail
        let center = center
        tail = Task { @MainActor in
            await previous?.value
            if ask { _ = await center.requestAuthorization() }
            for notice in notices { await center.add(notice) }
        }
    }
}

/// The notifier and the poster, fed by every read the outbox applies.
@MainActor
public final class TransferNotifications {
    let notifier: TransferNotifier
    let poster: TransferNoticePoster
    private let frontmost: @MainActor () -> Bool

    public init(
        defaults: UserDefaults,
        center: any TransferNoticeCenter = SystemNoticeCenter(),
        frontmost: @escaping @MainActor () -> Bool
    ) {
        notifier = TransferNotifier(defaults: defaults)
        poster = TransferNoticePoster(center: center)
        self.frontmost = frontmost
    }

    /// Kept alive by the outbox's hook from here on.
    public func attach(to outbox: Outbox) {
        outbox.onRefresh { [weak outbox] in
            guard let outbox else { return }
            self.observe(outbox)
        }
    }

    func observe(_ outbox: Outbox) {
        poster.post(
            notifier.observe(
                jobs: outbox.transfers.jobs,
                resolved: outbox.resolvedMemos,
                frontmost: frontmost(),
                now: Date(),
                lastProgressAt: outbox.lastProgressAt,
                verdict: outbox.uploadVerdict
            ))
    }
}

/// A tapped notification's route, until the screens that can follow it have.
@MainActor
@Observable
public final class TransferNoticeInbox {
    /// The one the app's notification delegate delivers into.
    public static let shared = TransferNoticeInbox()

    public private(set) var pending: TransferNoticeRoute?

    public init() {}

    public func deliver(_ route: TransferNoticeRoute) {
        pending = route
    }

    /// Hands a memo route to the app's own memo jump and returns the tab either route opens; a
    /// transfers route stays pending for the Timeline, which owns the sheet.
    func dispatch(into jump: MemoJump) -> MainTab? {
        switch pending {
        case nil:
            return nil
        case .memo(let uid):
            pending = nil
            jump.request(uid)
            return .timeline
        case .transfers:
            return .timeline
        }
    }

    /// The capture whose transfers row a tap asked for, taken once.
    func takeTransfers() -> UUID? {
        guard case .transfers(let jobID) = pending else { return nil }
        pending = nil
        return jobID
    }
}
