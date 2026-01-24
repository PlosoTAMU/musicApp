import Foundation
import SwiftUI

class DownloadManager: ObservableObject {
    @Published var downloads: [Download] = []
    private var deletionTimers: [UUID: Timer] = [:]
    
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
    
    func markForDeletion(_ download: Download, onDelete: @escaping (Download) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }) else { return }
        
        // If already pending, cancel it
        if downloads[index].pendingDeletion {
            cancelDeletion(download)
            return
        }
        
        // Mark as pending deletion
        downloads[index].pendingDeletion = true
        objectWillChange.send()
        
        // Set timer for actual deletion (5 seconds)
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.confirmDeletion(download, onDelete: onDelete)
        }
        
        deletionTimers[download.id] = timer
    }
    
    func cancelDeletion(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }) else { return }
        
        downloads[index].pendingDeletion = false
        deletionTimers[download.id]?.invalidate()
        deletionTimers.removeValue(forKey: download.id)
        objectWillChange.send()
    }
    
    private func confirmDeletion(_ download: Download, onDelete: @escaping (Download) -> Void) {
        // Notify audio player to stop if this is playing
        onDelete(download)
        
        // Delete the actual file
        try? FileManager.default.removeItem(at: download.url)
        
        // Delete thumbnail if exists
        if let thumbPath = download.thumbnailPath {
            try? FileManager.default.removeItem(atPath: thumbPath)
        }
        
        // Remove from memory and storage
        downloads.removeAll { $0.id == download.id }
        deletionTimers.removeValue(forKey: download.id)
        saveDownloads()
    }
    
    func getDownload(byID id: UUID) -> Download? {
        downloads.first { $0.id == id && !$0.pendingDeletion }
    }
    
    func hasVideoID(_ videoID: String) -> Bool {
        return downloads.contains { $0.videoID == videoID && !$0.pendingDeletion }
    }
    
    func hasDuplicate(videoID: String?, url: URL) -> Download? {
        // Check by video ID first
        if let videoID = videoID {
            if let existing = downloads.first(where: { $0.videoID == videoID && !$0.pendingDeletion }) {
                return existing
            }
        }
        
        // Check by filename (without extension)
        let newFileName = url.deletingPathExtension().lastPathComponent
        if let existing = downloads.first(where: {
            $0.url.deletingPathExtension().lastPathComponent == newFileName && !$0.pendingDeletion
        }) {
            return existing
        }
        
        return nil
    }
    
    private func saveDownloads() {
        do {
            let encoder = JSONEncoder()
            // Only save downloads that aren't pending deletion
            let downloadsToSave = downloads.filter { !$0.pendingDeletion }
            let data = try encoder.encode(downloadsToSave)
            try data.write(to: downloadsFileURL)
            print("✅ [DownloadManager] Saved \(downloadsToSave.count) downloads")
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
            var loadedDownloads = try decoder.decode([Download].self, from: data)
            
            // Ensure all loaded downloads have pendingDeletion = false
            for i in 0..<loadedDownloads.count {
                loadedDownloads[i].pendingDeletion = false
            }
            
            downloads = loadedDownloads
            
            // Validate thumbnails exist, regenerate if missing
            validateThumbnails()
            
            print("✅ [DownloadManager] Loaded \(downloads.count) downloads")
        } catch {
            print("❌ [DownloadManager] Failed to load: \(error)")
            // Try to recover by loading as empty array
            downloads = []
        }
    }
    
    private func validateThumbnails() {
        for (index, download) in downloads.enumerated() {
            if let thumbPath = download.thumbnailPath {
                if !FileManager.default.fileExists(atPath: thumbPath) {
                    print("⚠️ [DownloadManager] Missing thumbnail for: \(download.name)")
                    downloads[index].thumbnailPath = nil
                }
            }
        }
    }
}