import Foundation

enum IncomingShareQueue {
    static let appGroupID = "group.com.yourcompany.ploso" // Change to match YOUR app group
    static let queueFilename = "incoming_urls.json"

    static func enqueue(_ urlString: String) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            print("❌ Failed to get app group container")
            return
        }

        let fileURL = container.appendingPathComponent(queueFilename)

        var existing: [String] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            existing = decoded
        }

        // Add if not duplicate
        if !existing.contains(urlString) {
            existing.append(urlString)
        }

        if let data = try? JSONEncoder().encode(existing) {
            try? data.write(to: fileURL, options: .atomic)
            print("✅ Enqueued URL: \(urlString)")
        }
    }
    
    static func drain() -> [String] {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return []
        }
        let fileURL = container.appendingPathComponent(queueFilename)

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        // Clear queue
        try? FileManager.default.removeItem(at: fileURL)
        return decoded
    }
}