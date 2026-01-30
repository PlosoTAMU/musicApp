import Foundation

enum IncomingShareQueue {
    // MUST match the App Group you created
    static let appGroupID = "group.Ploso.musicApp.share"
    static let queueFilename = "incoming_urls.json"
    
    static func enqueue(_ urlString: String) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            print("❌ Failed to get app group container - check entitlements!")
            return
        }
        
        let fileURL = container.appendingPathComponent(queueFilename)
        
        var existing: [String] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            existing = decoded
        }
        
        if !existing.contains(urlString) {
            existing.append(urlString)
        }
        
        if let data = try? JSONEncoder().encode(existing) {
            try? data.write(to: fileURL, options: .atomic)
            print("✅ Enqueued URL: \(urlString)")
        }
    }
    
    static func drain() -> [String] {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            print("❌ Failed to get app group container for drain")
            return []
        }
        
        let fileURL = container.appendingPathComponent(queueFilename)
        
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        
        // Clear the queue
        try? FileManager.default.removeItem(at: fileURL)
        
        print("📤 Drained \(decoded.count) URLs")
        return decoded
    }
}