import AppKit
import UserNotifications

/// Native macOS notifications layered on top of (not replacing) the existing
/// iMessage + plain `osascript display notification` alerts already fired
/// independently by backup-engine.sh. This is purely an additional, richer
/// channel owned by the native shell.
final class NotificationsManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationsManager()

    weak var appDelegate: AppDelegate?

    private let categoryId = "BACKUP_RESULT"
    private let openPanelActionId = "OPEN_PANEL"
    private let viewLogActionId = "VIEW_LOG"

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let openPanel = UNNotificationAction(identifier: openPanelActionId, title: "Ouvrir le panneau", options: [.foreground])
        let viewLog = UNNotificationAction(identifier: viewLogActionId, title: "Voir le journal", options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryId, actions: [openPanel, viewLog], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("NotificationsManager: authorization request failed: \(error)")
            }
        }
    }

    func postJobFinished(title: String, body: String, logPath: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryId
        content.sound = .default
        if let logPath {
            content.userInfo = ["logPath": logPath]
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("NotificationsManager: failed to post notification: \(error)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        let logPath = response.notification.request.content.userInfo["logPath"] as? String

        switch response.actionIdentifier {
        case viewLogActionId:
            if let logPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
            }
            appDelegate?.bringPanelToFront()
        default:
            appDelegate?.bringPanelToFront()
        }
        completionHandler()
    }
}
