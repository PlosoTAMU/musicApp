import SwiftUI
import FirebaseCore // Make sure FirebaseCore is imported

// 1. Define your AppDelegate class to handle Firebase initialization
// (also the orientation-lock hook — NowPlayingView sets orientationLock;
// there must be exactly ONE AppDelegate or both declarations fail to build)
class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        // Initialize Firebase
        FirebaseApp.configure()

        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}

@main
struct musicAppApp: App {
    // 2. This links your AppDelegate to the SwiftUI lifecycle
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // Initialize Python when app launches
        EmbeddedPython.shared.initialize()

        // Register Siri App Shortcuts as early as possible
        if #available(iOS 16.0, *) {
            MusicAppShortcuts.updateAppShortcutParameters()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
