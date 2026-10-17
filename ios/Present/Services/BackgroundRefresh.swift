import BackgroundTasks
import Foundation

/// Opportunistic background fetch so today's session is often already downloaded
/// (and playable offline) by the time it's opened. iOS decides when this actually runs.
enum BackgroundRefresh {
    static let identifier = "com.present.meditation.refresh"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule(earliest: Date?) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest ?? Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Unsupported in the simulator and when Background App Refresh is off; that's fine.
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let work = Task { @MainActor in
            let success = await AppModel.shared.backgroundRefresh()
            task.setTaskCompleted(success: success)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}
