import SwiftUI

@main
struct musicAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    init() {
        // Initialize Python when app launches
        EmbeddedPython.shared.initialize()

        // Register Siri App Shortcuts as early as possible so "Hey Siri, play X
        // in Pulsor" is recognized. Re-running it refreshes the song vocabulary.
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