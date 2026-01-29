import Foundation

enum IncomingShareQueue {
    static let appGroupID = "group.com.ploso.ploso"
    static let queueFilename = "incoming_urls.json"

    static func enqueue(_ urlString: String) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }

        let fileURL = container.appendingPathComponent(queueFilename)

        var existing: [String] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            existing = decoded
        }

        // de-dupe (optional)
        if !existing.contains(urlString) {
            existing.append(urlString)
        }

        if let data = try? JSONEncoder().encode(existing) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}