import Foundation
import SwiftUI

class DownloadManager: ObservableObject {
    @Published var downloads: [Download] = []
    private var deletionTimers: [UUID: Timer] = [:]
    
    private let downloadsFileURL: URL
    private let musicDirectory: URL
    
    init() {
        // Store in Files app accessible location
        let fileManager = FileManager.default
        
        // Get the app's Documents directory (visible in Files app)
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // Create a Music folder
        musicDirectory = documentsPath.appendingPathComponent("Music", isDirectory: true)
        try? fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        
        // Make it visible in Files app
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = false
        try? (musicDirectory as NSURL).setResourceValues(resourceValues)
        
        downloadsFileURL = documentsPath.appendingPathComponent("downloads.json")
        
        print("📁 Music directory: \(musicDirectory.path)")
        loadDownloads()
    }
    
    var sortedDownloads: [Download] {
        downloads.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    func getMusicDirectory() -> URL {
        return musicDirectory
    }
    
    func addDownload(_ download: Download) {
        // Ensure the file is in the Music directory
        let targetURL = musicDirectory.appendingPathComponent(download.url.lastPathComponent)
        
        // Move file if not already there
        if download.url != targetURL {
            try? FileManager.default.moveItem(at: download.url, to: targetURL)
            
            // Update download with new URL
            var updatedDownload = download
            updatedDownload = Download(
                id: download.id,
                name: download.name,
                url: targetURL,
                thumbnailPath: download.thumbnailPath,
                videoID: download.videoID,
                source: download.source
            )
            downloads.append(updatedDownload)
        } else {
            downloads.append(download)
        }
        
        saveDownloads()
    }
    
    func markForDeletion(_ download: Download, onDelete: @escaping (Download) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }) else { return }
        
        if downloads[index].pendingDeletion {
            cancelDeletion(download)
            return
        }
        
        downloads[index].pendingDeletion = true
        objectWillChange.send()
        
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
        onDelete(download)
        
        try? FileManager.default.removeItem(at: download.url)
        
        if let thumbPath = download.thumbnailPath {
            try? FileManager.default.removeItem(atPath: thumbPath)
        }
        
        downloads.removeAll { $0.id == download.id }
        deletionTimers.removeValue(forKey: download.id)
        saveDownloads()
    }
    
    func getDownload(byID id: UUID) -> Download? {
        downloads.first { $0.id == id && !$0.pendingDeletion }
    }
    
    func findDuplicateByVideoID(videoID: String, source: DownloadSource) -> Download? {
        if let existing = downloads.first(where: { 
            $0.videoID == videoID && 
            $0.source == source && 
            !$0.pendingDeletion 
        }) {
            print("🔍 [Duplicate] Found exact match by videoID: \(existing.name)")
            return existing
        }
        
        if source == .youtube {
            let cleanVideoID = videoID.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
            
            if let existing = downloads.first(where: { download in
                guard download.source == .youtube, 
                      !download.pendingDeletion,
                      let storedID = download.videoID else { return false }
                
                let cleanStoredID = storedID.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
                return cleanStoredID == cleanVideoID
            }) {
                print("🔍 [Duplicate] Found match by cleaned videoID: \(existing.name)")
                return existing
            }
            
            if let existing = downloads.first(where: { download in
                guard download.source == .youtube, !download.pendingDeletion else { return false }
                let filename = download.url.lastPathComponent
                return filename.contains(videoID)
            }) {
                print("🔍 [Duplicate] Found match by filename: \(existing.name)")
                return existing
            }
        }
        
        if source == .spotify {
            if let existing = downloads.first(where: { download in
                guard download.source == .spotify,
                      !download.pendingDeletion,
                      let storedID = download.videoID else { return false }
                return storedID == videoID
            }) {
                print("🔍 [Duplicate] Found Spotify match: \(existing.name)")
                return existing
            }
        }
        
        print("✅ [Duplicate] No duplicate found for videoID: \(videoID)")
        return nil
    }
    
    private func saveDownloads() {
        do {
            let encoder = JSONEncoder()
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
            
            // Verify files still exist
            loadedDownloads = loadedDownloads.filter { download in
                let exists = FileManager.default.fileExists(atPath: download.url.path)
                if !exists {
                    print("⚠️ [DownloadManager] Missing file: \(download.name)")
                }
                return exists
            }
            
            for i in 0..<loadedDownloads.count {
                loadedDownloads[i].pendingDeletion = false
            }
            
            downloads = loadedDownloads
            validateThumbnails()
            
            print("✅ [DownloadManager] Loaded \(downloads.count) downloads from Music folder")
        } catch {
            print("❌ [DownloadManager] Failed to load: \(error)")
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