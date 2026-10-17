import Foundation

/// Launch-argument overrides, used by UI tests and for local development.
///
///   -PresentServerURL <url> -PresentToken <token>   connect to a server, skip onboarding
///   -PresentResetState YES                          wipe local state before launch
///   -PresentDemoOnly YES                            skip onboarding into the bundled demo
///   -PresentFastFinish YES                          sessions finish after 3 s (tests only)
///   -PresentUITest YES                              disable continuous animations
struct LaunchOptions {
    var serverURL: String?
    var token: String?
    var resetState = false
    var demoOnly = false
    var fastFinish = false
    var isUITest = false

    static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: "-" + key), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        func flag(_ key: String) -> Bool {
            guard let v = value(key)?.lowercased() else { return false }
            return v == "yes" || v == "true" || v == "1"
        }
        serverURL = value("PresentServerURL")
        token = value("PresentToken")
        resetState = flag("PresentResetState")
        demoOnly = flag("PresentDemoOnly")
        fastFinish = flag("PresentFastFinish")
        isUITest = flag("PresentUITest")
    }
}
