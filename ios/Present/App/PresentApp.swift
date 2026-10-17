import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        BackgroundRefresh.register()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            await AppModel.shared.didRegisterForPush(token: token)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected when the app is signed without the Push capability (free Apple ID).
        print("Present: remote notifications unavailable: \(error.localizedDescription)")
        Task { @MainActor in
            await AppModel.shared.didFailToRegisterForPush()
        }
    }
}

@main
struct PresentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Navigation titles ("Library", "Settings") in the same serif as the rest of the app.
        let ink = UIColor(Palette.ink)
        func serif(_ style: UIFont.TextStyle) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style)
            let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return UIFont(descriptor: descriptor, size: base.pointSize)
        }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [.font: serif(.largeTitle), .foregroundColor: ink]
        appearance.titleTextAttributes = [.font: serif(.headline), .foregroundColor: ink]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Palette.accent)
                .task {
                    await model.refresh()
                    await model.setUpNotifications()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await model.refresh() }
            case .background:
                model.lockJournal()
                model.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }
}
