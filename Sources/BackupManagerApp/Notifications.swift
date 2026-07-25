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
    private let upcomingCategoryId = "BACKUP_UPCOMING"
    private let skipOnceActionId = "SKIP_ONCE"

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let openPanel = UNNotificationAction(identifier: openPanelActionId, title: "Ouvrir le panneau", options: [.foreground])
        let viewLog = UNNotificationAction(identifier: viewLogActionId, title: "Voir le journal", options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryId, actions: [openPanel, viewLog], intentIdentifiers: [], options: [])

        // « Sauvegarde imminente » : une seule action, et surtout PAS un report
        // qui décalerait l'heure dans launchd -- la planification d'origine doit
        // rester intacte. « Sauter cette fois » retire l'agent du seul job
        // concerné et le réarme juste après l'heure manquée (voir api_skip_next
        // côté backend) : même effet pour l'utilisateur, réglage préservé.
        let skipOnce = UNNotificationAction(identifier: skipOnceActionId,
                                            title: "Sauter cette fois", options: [])
        let upcoming = UNNotificationCategory(identifier: upcomingCategoryId,
                                              actions: [skipOnce], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, upcoming])

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("NotificationsManager: authorization request failed: \(error)")
            }
            if !granted {
                NSLog("NotificationsManager: user denied notification authorization — no native notifications will be shown")
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

    /// Prévient qu'une sauvegarde va démarrer, avec l'option de la sauter.
    func postBackupUpcoming(jobId: String, jobName: String, minutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = jobName
        content.body = "Sauvegarde dans \(minutes) min."
        content.categoryIdentifier = upcomingCategoryId
        content.userInfo = ["jobId": jobId]
        // Pas de son : c'est une information anticipée, pas un événement.
        let request = UNNotificationRequest(identifier: "upcoming-\(jobId)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("NotificationsManager: failed to post upcoming notification: \(error)")
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
        case skipOnceActionId:
            if let jobId = response.notification.request.content.userInfo["jobId"] as? String {
                appDelegate?.skipNextRun(jobId: jobId)
            }
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
