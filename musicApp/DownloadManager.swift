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

        let targetDownloadID = activeDownload.id
        
        // Set up callback BEFORE starting download
        EmbeddedPython.shared.onTitleFetched = { [weak self] callbackVideoID, callbackTitle in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                print("🔍 [DownloadManager] Callback fired with videoID: \(callbackVideoID), title: \(callbackTitle)")
                print("🔍 [DownloadManager] Active downloads: \(self.activeDownloads.map { "{\($0.videoID): \($0.title)}" }.joined(separator: ", "))")
                
                // FIXED: Update title in place instead of replacing entire object
                if let index = self.activeDownloads.firstIndex(where: { $0.id == targetDownloadID }) {
                    print("✅ [DownloadManager] MATCH FOUND at index \(index)")
                    self.activeDownloads[index].title = callbackTitle
                    self.activeDownloads[index].progress = 0.5
                    self.objectWillChange.send() // Force UI update
                    print("📝 [DownloadManager] Updated title to: \(callbackTitle)")
                } else {
                    print("❌ [DownloadManager] NO MATCH FOUND for videoID: \(callbackVideoID)")
                    print("❌ [DownloadManager] Trying fuzzy match...")
                    
                    // AGGRESSIVE FIX: Try to find by partial match
                    if let index = self.activeDownloads.firstIndex(where: { 
                        $0.videoID.contains(callbackVideoID) || callbackVideoID.contains($0.videoID)
                    }) {
                        print("✅ [DownloadManager] FUZZY MATCH FOUND at index \(index)")
                        self.activeDownloads[index].title = callbackTitle
                        self.activeDownloads[index].progress = 0.5
                        self.objectWillChange.send()
                    } else {
                        print("❌ [DownloadManager] NO FUZZY MATCH EITHER!")
                    }
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

                DispatchQueue.global(qos: .utility).async {
                    if let audioURL = self.getDownloadedFileURL(for: videoID),
                    let waveform = WaveformGenerator.generate(from: audioURL, targetSamples: 100) {
                        
                        let waveformURL = self.getWaveformURL(for: videoID)
                        WaveformGenerator.save(waveform, to: waveformURL)
                        print("✅ Waveform saved: \(waveform.count) samples")
                    }
                }
                
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

    private func getWaveformURL(for videoID: String) -> URL {
        let waveformsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waveforms", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: waveformsDir, withIntermediateDirectories: true)
        return waveformsDir.appendingPathComponent("\(videoID).waveform")
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
                
                // FIXED: Store only the FILENAME, not full path
                var thumbnailFilename: String? = nil
                if let thumbPath = download.thumbnailPath {
                    thumbnailFilename = URL(fileURLWithPath: thumbPath).lastPathComponent
                }
                
                finalDownload = Download(
                    id: download.id,
                    name: download.name,
                    url: targetURL,
                    thumbnailPath: thumbnailFilename,  // Just filename now
                    videoID: download.videoID,
                    source: download.source
                )
            } catch {
                print("❌ [DownloadManager] Failed to move file: \(error)")
                finalDownload = download
            }
        } else {
            // FIXED: Also convert existing full path to filename
            if let thumbPath = download.thumbnailPath {
                let thumbnailFilename = URL(fileURLWithPath: thumbPath).lastPathComponent
                finalDownload = Download(
                    id: download.id,
                    name: download.name,
                    url: download.url,
                    thumbnailPath: thumbnailFilename,
                    videoID: download.videoID,
                    source: download.source
                )
            }
        }
        
        downloads.append(finalDownload)
        saveDownloads()
        objectWillChange.send()
    }
    
    func getThumbnailFullPath(for download: Download) -> String? {
        guard let thumbnailFilename = download.thumbnailPath else { return nil }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let thumbnailsDir = documentsPath.appendingPathComponent("Thumbnails", isDirectory: true)
        let fullPath = thumbnailsDir.appendingPathComponent(thumbnailFilename).path
        
        if FileManager.default.fileExists(atPath: fullPath) {
            return fullPath
        }
        return nil
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
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let thumbnailsDir = documentsPath.appendingPathComponent("Thumbnails", isDirectory: true)
        
        for (index, download) in downloads.enumerated() {
            // FIXED: Use resolvedThumbnailPath instead of raw thumbnailPath
            if let resolvedPath = download.resolvedThumbnailPath {
                if FileManager.default.fileExists(atPath: resolvedPath) {
                    print("✅ [DownloadManager] Thumbnail found for: \(download.name)")
                    
                    // FIXED: Migrate old absolute paths to just filename
                    if let oldPath = download.thumbnailPath, oldPath.contains("/") {
                        downloads[index].thumbnailPath = (oldPath as NSString).lastPathComponent
                        needsSave = true
                    }
                } else {
                    print("⚠️ [DownloadManager] Missing thumbnail for: \(download.name)")
                    
                    if let videoID = download.videoID, !videoID.isEmpty {
                        EmbeddedPython.shared.ensureThumbnail(for: download.url, videoID: videoID)
                    }
                }
            } else if let videoID = download.videoID, !videoID.isEmpty {
                print("🔄 [DownloadManager] No thumbnail path for: \(download.name), generating...")
                EmbeddedPython.shared.ensureThumbnail(for: download.url, videoID: videoID)
            }
        }
        
        if needsSave {
            saveDownloads()
        }
        print("✅ [DownloadManager] Thumbnail validation complete")
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