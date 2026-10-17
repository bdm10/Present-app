import Foundation
import UIKit
import UserNotifications

/// Notification permission, remote (APNs) registration, and the local fallback reminder.
@MainActor
enum NotificationManager {
    static let localReminderID = "present.daily.reminder"

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks once; returns whether alerts are allowed.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Registers with APNs. Free Apple IDs cannot use push; that failure is handled in AppDelegate.
    static func registerForRemoteIfAuthorized() async {
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Local fallback when the server cannot push: a gentle daily reminder at the chosen time.
    static func scheduleLocalReminder(hour: Int, minute: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [localReminderID])
        let content = UNMutableNotificationContent()
        content.title = "Present"
        content.body = "Your morning session is ready when you are."
        content.sound = .default
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: localReminderID, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            print("Present: could not schedule reminder: \(error)")
        }
    }

    static func cancelLocalReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [localReminderID])
    }
}

/// Handles notification presentation and taps (kept separate from the app delegate
/// so its callbacks don't inherit main-actor isolation).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
        Task { @MainActor in
            await AppModel.shared.refresh()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
        Task { @MainActor in
            AppModel.shared.selectedTab = .today
            await AppModel.shared.refresh()
        }
    }
}
