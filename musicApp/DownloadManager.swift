import Foundation
import SwiftUI

class DownloadManager: ObservableObject {
    @Published var downloads: [Download] = []
    
    private let downloadsFileURL: URL
    
    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadsFileURL = documentsPath.appendingPathComponent("downloads.json")
        loadDownloads()
    }
    
    var sortedDownloads: [Download] {
        downloads.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    func addDownload(_ download: Download) {
        downloads.append(download)
        saveDownloads()
    }
    
    func deleteDownload(_ download: Download) {
        // Delete the actual file
        try? FileManager.default.removeItem(at: download.url)
        
        // Delete thumbnail if exists
        if let thumbPath = download.thumbnailPath {
            try? FileManager.default.removeItem(atPath: thumbPath)
        }
        
        // Remove from list
        downloads.removeAll { $0.id == download.id }
        saveDownloads()
    }
    
    func getDownload(byID id: UUID) -> Download? {
        downloads.first { $0.id == id }
    }
    
    private func saveDownloads() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(downloads)
            try data.write(to: downloadsFileURL)
            print("✅ [DownloadManager] Saved \(downloads.count) downloads")
        } catch {
            print("❌ [DownloadManager] Failed to save: \(error)")
        }
    }
    
    private func loadDownloads() {
        guard FileManager.default.fileExists(atPath: downloadsFileURL.path) else {
            print("ℹ️ [DownloadManager] No saved downloads")
            return
        }
        
        do {
            let data = try Data(contentsOf: downloadsFileURL)
            let decoder = JSONDecoder()
            downloads = try decoder.decode([Download].self, from: data)
            print("✅ [DownloadManager] Loaded \(downloads.count) downloads")
        } catch {
            print("❌ [DownloadManager] Failed to load: \(error)")
        }
    }
}