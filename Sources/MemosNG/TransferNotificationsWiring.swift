import MemosFeatures
import MemosOutbox
import UIKit
import UserNotifications

/// The transfer notifications (MEMNG-949), composed beside the outbox they read: posted while the
/// app is not frontmost, and a tap on one handed to the screens that follow it.
extension MemosNGAppDelegate: UNUserNotificationCenterDelegate {
    func attachTransferNotifications(to outbox: Outbox?) {
        UNUserNotificationCenter.current().delegate = self
        guard let outbox else { return }
        // Read when each notice is decided: a process the system launched to finish an upload
        // has no scene in front, and the application state says so as well as a scene would.
        TransferNotifications(
            defaults: .standard,
            frontmost: { UIApplication.shared.applicationState == .active }
        ).attach(to: outbox)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let route = TransferNoticeRoute(userInfo: userInfo) else { return }
        await MainActor.run { TransferNoticeInbox.shared.deliver(route) }
    }
}
