import SwiftUI
import FirebaseCore // Make sure FirebaseCore is imported

// 1. Define your AppDelegate class to handle Firebase initialization
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        // Initialize Firebase
        FirebaseApp.configure()
        
        return true
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
