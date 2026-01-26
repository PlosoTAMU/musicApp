import Foundation
import SwiftUI

class DownloadManager: ObservableObject {
    @Published var downloads: [Download] = []
    @Published var activeDownloads: [ActiveDownload] = []
    private var deletionTimers: [UUID: Timer] = [:]
    
    private let downloadsFileURL: URL
    private let musicDirectory: URL
    
    init() {
        let fileManager = FileManager.default
        
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        musicDirectory = documentsPath.appendingPathComponent("Music", isDirectory: true)
        try? fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = false
        var musicDirURL = musicDirectory
        try? musicDirURL.setResourceValues(resourceValues)
        
        downloadsFileURL = documentsPath.appendingPathComponent("downloads.json")
        
        print("📂 Music directory: \(musicDirectory.path)")
        
        loadDownloads()
        // FIXED: Validate and fix thumbnails on boot
        validateAndFixThumbnails()
    }
    
    var sortedDownloads: [Download] {
        downloads.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    func getMusicDirectory() -> URL {
        return musicDirectory
    }
    
    func startBackgroundDownload(url: String, videoID: String, source: DownloadSource, title: String = "Fetching info") {
        let activeDownload = ActiveDownload(id: UUID(), videoID: videoID, title: title, progress: 0.0)
        activeDownloads.append(activeDownload)
        
        // Set up callback BEFORE starting download
        EmbeddedPython.shared.onTitleFetched = { [weak self] callbackVideoID, callbackTitle in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let index = self.activeDownloads.firstIndex(where: { $0.videoID == callbackVideoID }) {
                    self.activeDownloads[index] = ActiveDownload(
                        id: self.activeDownloads[index].id,
                        videoID: callbackVideoID,
                        title: callbackTitle,
                        progress: 0.5
                    )
                    print("📝 [DownloadManager] Updated title to: \(callbackTitle)")
                }
            }
        }
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                let (fileURL, downloadedTitle) = try await EmbeddedPython.shared.downloadAudio(url: url, videoID: videoID)
                
                var thumbnailPath: URL? = nil
                for attempt in 1...5 {
                    await Task.sleep(1_000_000_000)
                    thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: fileURL)
                    if thumbnailPath != nil { break }
                    print("🔄 Thumbnail check \(attempt)/5")
                }
                
                if thumbnailPath == nil && !videoID.isEmpty {
                    EmbeddedPython.shared.ensureThumbnail(for: fileURL, videoID: videoID)
                    await Task.sleep(2_000_000_000)
                    thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: fileURL)
                }
                
                let download = Download(
                    name: downloadedTitle,
                    url: fileURL,
                    thumbnailPath: thumbnailPath?.path,
                    videoID: videoID,
                    source: source
                )
                
                await MainActor.run {
                    self.activeDownloads.removeAll { $0.videoID == videoID }
                    self.addDownload(download)
                }
            } catch {
                print("❌ Background download failed: \(error)")
                await MainActor.run {
                    self.activeDownloads.removeAll { $0.videoID == videoID }
                }
            }
        }
    }
    
    func addDownload(_ download: Download) {
        let targetURL = musicDirectory.appendingPathComponent(download.url.lastPathComponent)
        
        var finalDownload = download
        
        if download.url.path != targetURL.path {
            do {
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                
                try FileManager.default.moveItem(at: download.url, to: targetURL)
                print("✅ [DownloadManager] Moved file to Music directory: \(targetURL.lastPathComponent)")
                
                finalDownload = Download(
                    id: download.id,
                    name: download.name,
                    url: targetURL,
                    thumbnailPath: download.thumbnailPath,
                    videoID: download.videoID,
                    source: download.source
                )
            } catch {
                print("❌ [DownloadManager] Failed to move file: \(error)")
                finalDownload = download
            }
        }
        
        downloads.append(finalDownload)
        saveDownloads()
        objectWillChange.send() // FIXED: Force UI update
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
        
        do {
            if FileManager.default.fileExists(atPath: download.url.path) {
                try FileManager.default.removeItem(at: download.url)
                print("✅ [DownloadManager] Deleted audio file: \(download.url.lastPathComponent)")
            }
        } catch {
            print("❌ [DownloadManager] Failed to delete audio file: \(error)")
        }
        
        if let thumbPath = download.thumbnailPath {
            do {
                if FileManager.default.fileExists(atPath: thumbPath) {
                    try FileManager.default.removeItem(atPath: thumbPath)
                    print("✅ [DownloadManager] Deleted thumbnail: \(thumbPath)")
                }
            } catch {
                print("❌ [DownloadManager] Failed to delete thumbnail: \(error)")
            }
        }
        
        let metadataURL = getMetadataFileURL()
        var metadata = loadMetadata()
        let filename = download.url.lastPathComponent
        metadata.removeValue(forKey: filename)
        
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL)
            print("✅ [DownloadManager] Removed metadata entry")
        } catch {
            print("❌ [DownloadManager] Failed to update metadata: \(error)")
        }
        
        downloads.removeAll { $0.id == download.id }
        deletionTimers.removeValue(forKey: download.id)
        saveDownloads()
        
        print("🗑️ [DownloadManager] Completely removed: \(download.name)")
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
            
            let currentMusicDir = musicDirectory
            
            for i in 0..<loadedDownloads.count {
                let filename = loadedDownloads[i].url.lastPathComponent
                let correctPath = currentMusicDir.appendingPathComponent(filename)
                
                loadedDownloads[i] = Download(
                    id: loadedDownloads[i].id,
                    name: loadedDownloads[i].name,
                    url: correctPath,
                    thumbnailPath: loadedDownloads[i].thumbnailPath,
                    videoID: loadedDownloads[i].videoID,
                    source: loadedDownloads[i].source
                )
                
                loadedDownloads[i].pendingDeletion = false
                
                if !FileManager.default.fileExists(atPath: correctPath.path) {
                    print("⚠️ [DownloadManager] Missing file: \(filename) at \(correctPath.path)")
                } else {
                    print("✅ [DownloadManager] Found file: \(filename)")
                }
            }
            
            loadedDownloads = loadedDownloads.filter { download in
                FileManager.default.fileExists(atPath: download.url.path)
            }
            
            downloads = loadedDownloads
            
            print("✅ [DownloadManager] Loaded \(downloads.count) downloads from Music folder")
        } catch {
            print("❌ [DownloadManager] Failed to load: \(error)")
            downloads = []
        }
    }
    
    // FIXED: Validate and regenerate missing thumbnails on boot
    private func validateAndFixThumbnails() {
        print("🔍 [DownloadManager] Validating thumbnails...")
        var needsSave = false
        
        for (index, download) in downloads.enumerated() {
            // Check if thumbnail path exists and is valid
            if let thumbPath = download.thumbnailPath {
                if !FileManager.default.fileExists(atPath: thumbPath) || UIImage(contentsOfFile: thumbPath) == nil {
                    print("⚠️ [DownloadManager] Invalid thumbnail for: \(download.name), regenerating...")
                    
                    // Try to regenerate thumbnail
                    if let videoID = download.videoID, !videoID.isEmpty {
                        EmbeddedPython.shared.ensureThumbnail(for: download.url, videoID: videoID)
                        
                        // Update path after potential regeneration
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            if let newPath = EmbeddedPython.shared.getThumbnailPath(for: download.url) {
                                self.downloads[index].thumbnailPath = newPath.path
                                self.saveDownloads()
                                self.objectWillChange.send()
                            }
                        }
                    } else {
                        downloads[index].thumbnailPath = nil
                        needsSave = true
                    }
                }
            } else if let videoID = download.videoID, !videoID.isEmpty {
                // No thumbnail path but has videoID - try to generate
                print("🔄 [DownloadManager] No thumbnail for: \(download.name), attempting to generate...")
                EmbeddedPython.shared.ensureThumbnail(for: download.url, videoID: videoID)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if let newPath = EmbeddedPython.shared.getThumbnailPath(for: download.url) {
                        self.downloads[index].thumbnailPath = newPath.path
                        self.saveDownloads()
                        self.objectWillChange.send()
                    }
                }
            }
        }
        
        if needsSave {
            saveDownloads()
            print("✅ [DownloadManager] Thumbnail validation complete, changes saved")
        } else {
            print("✅ [DownloadManager] All thumbnails valid")
        }
    }
    
    private func getMetadataFileURL() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("audio_metadata.json")
    }
    
    private func loadMetadata() -> [String: [String: String]] {
        let metadataURL = getMetadataFileURL()
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }
        return metadata
    }
}