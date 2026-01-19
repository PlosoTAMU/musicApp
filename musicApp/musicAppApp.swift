import SwiftUI

@main
struct musicAppApp: App {
    init() {
        // Initialize Python when app launches
        EmbeddedPython.shared.initialize()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}