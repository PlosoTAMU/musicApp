import Foundation
import SwiftUI

class DownloadManager: ObservableObject {
    @Published var downloads: [Download] = [] {
        didSet {
            // ✅ PERFORMANCE: Cache sorted downloads instead of re-sorting on every access
            _sortedDownloadsCache = nil
        }
    }
    @Published var activeDownloads: [ActiveDownload] = []
    private var deletionTimers: [UUID: Timer] = [:]
    private let timerLock = NSLock()
    
    // ✅ PERFORMANCE: Cached sorted downloads
    private var _sortedDownloadsCache: [Download]?
    var sortedDownloads: [Download] {
        if let cached = _sortedDownloadsCache {
            return cached
        }
        let sorted = downloads.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        _sortedDownloadsCache = sorted
        return sorted
    }
    
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
                
                if let index = self.activeDownloads.firstIndex(where: { $0.id == targetDownloadID }) {
                    self.activeDownloads[index].title = callbackTitle
                    self.activeDownloads[index].progress = 0.5
                    self.objectWillChange.send()
                }
            }
        }
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                // ✅ FIXED: Check if it's a Spotify URL and convert first
                var finalURL = url
                var finalVideoID = videoID
                
                if source == .spotify {
                    // Update status to show conversion
                    await MainActor.run {
                        if let index = self.activeDownloads.firstIndex(where: { $0.id == targetDownloadID }) {
                            self.activeDownloads[index].title = "Converting Spotify link..."
                            self.objectWillChange.send()
                        }
                    }
                    
                    // Convert Spotify to YouTube using the urllib-based script
                    finalURL = try await self.convertSpotifyToYouTube(spotifyURL: url)
                    
                    // Extract YouTube video ID from converted URL
                    if let extractedID = self.extractYouTubeID(from: finalURL) {
                        finalVideoID = extractedID
                    }
                    
                    print("✅ [DownloadManager] Converted Spotify to YouTube: \(finalURL)")
                    
                    // Update status
                    await MainActor.run {
                        if let index = self.activeDownloads.firstIndex(where: { $0.id == targetDownloadID }) {
                            self.activeDownloads[index].title = "Downloading from YouTube..."
                            self.objectWillChange.send()
                        }
                    }
                }
                
                // Now proceed with YouTube download
                let (fileURL, downloadedTitle) = try await EmbeddedPython.shared.downloadAudio(url: finalURL, videoID: finalVideoID)
                
                var thumbnailPath: URL? = nil
                for attempt in 1...5 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: fileURL)
                    if thumbnailPath != nil { break }
                    print("🔄 Thumbnail check \(attempt)/5")
                }
                
                if thumbnailPath == nil && !finalVideoID.isEmpty {
                    EmbeddedPython.shared.ensureThumbnail(for: fileURL, videoID: finalVideoID)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: fileURL)
                }
                
                let download = Download(
                    name: downloadedTitle,
                    url: fileURL,
                    thumbnailPath: thumbnailPath?.path,
                    videoID: finalVideoID,
                    source: source,  // Keep original source (.spotify) for UI icon
                    originalURL: url  // Store the original URL
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
    func renameDownload(_ download: Download, newName: String) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }) else { return }
        
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        // Update the download with new name
        downloads[index] = Download(
            id: download.id,
            name: trimmedName,
            url: download.url,
            thumbnailPath: download.thumbnailPath,
            videoID: download.videoID,
            source: download.source
        )
        
        saveDownloads()
        objectWillChange.send()
        print("✅ [DownloadManager] Renamed to: \(trimmedName)")
    }

    // ✅ ADD: Helper method to convert Spotify to YouTube
    private func convertSpotifyToYouTube(spotifyURL: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let resultFilePath = NSTemporaryDirectory() + "spotify_result_\(UUID().uuidString).json"
            
            let script = generateSpotifyConversionScript(spotifyURL: spotifyURL, resultFilePath: resultFilePath)
            
            DispatchQueue.global(qos: .userInitiated).async {
                // Execute Python script
                guard EmbeddedPython.shared.executePythonScript(script) else {
                    continuation.resume(throwing: NSError(domain: "SpotifyConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to execute Python script"]))
                    return
                }
                
                // Read result
                guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: resultFilePath)),
                    let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continuation.resume(throwing: NSError(domain: "SpotifyConversion", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to read result"]))
                    return
                }
                
                try? FileManager.default.removeItem(atPath: resultFilePath)
                
                guard let success = json["success"] as? Bool, success,
                    let youtubeURL = json["youtube_url"] as? String else {
                    let error = json["error"] as? String ?? "Unknown error"
                    continuation.resume(throwing: NSError(domain: "SpotifyConversion", code: -3, userInfo: [NSLocalizedDescriptionKey: error]))
                    return
                }
                
                continuation.resume(returning: youtubeURL)
            }
        }
    }

    // ✅ ADD: Generate Python script for Spotify conversion (using urllib - no dependencies)
    private func generateSpotifyConversionScript(spotifyURL: String, resultFilePath: String) -> String {
        let cleanURL = spotifyURL.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        
        return """
        import sys
        import json
        import requests
        import re
        
        def get_spotify_track_info(spotify_url):
            try:
                oembed_url = f"https://open.spotify.com/oembed?url={spotify_url}"
                response = requests.get(oembed_url, timeout=10)
                if response.status_code != 200:
                    return None
                data = response.json()
                title = data.get("title")  # format: "Track Name – Artist Name"
                return title
            except Exception as e:
                print(f"Error getting Spotify info: {e}")
                return None
        
        def search_youtube(query):
            try:
                query = query.replace(' ', '+')
                url = f"https://www.youtube.com/results?search_query={query}"
                headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
                
                response = requests.get(url, headers=headers, timeout=10)
                if response.status_code != 200:
                    return None
                
                # Find video IDs in the response
                video_ids = re.findall(r"watch\\?v=(\\S{11})", response.text)
                if video_ids:
                    return f"https://www.youtube.com/watch?v={video_ids[0]}"
                return None
            except Exception as e:
                print(f"Error searching YouTube: {e}")
                return None
        
        def spotify_to_youtube(spotify_url):
            track_info = get_spotify_track_info(spotify_url)
            if not track_info:
                return None, "Could not extract track info from Spotify"
            
            print(f"Found track: {track_info}")
            
            youtube_link = search_youtube(track_info)
            if not youtube_link:
                return None, "Could not find YouTube video for this track"
            
            return youtube_link, None
        
        # Main execution
        spotify_url = r'''\(cleanURL)'''
        result = {}
        
        try:
            youtube_url, error = spotify_to_youtube(spotify_url)
            if youtube_url:
                result = {
                    'success': True,
                    'youtube_url': youtube_url
                }
            else:
                result = {
                    'success': False,
                    'error': error or 'Unknown error'
                }
        except Exception as e:
            result = {
                'success': False,
                'error': str(e)
            }
        
        with open(r'''\(resultFilePath)''', 'w', encoding='utf-8') as f:
            json.dump(result, f)
        """
    }

    // ✅ ADD: Helper to extract YouTube video ID
    private func extractYouTubeID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let host = url.host?.lowercased() ?? ""
        
        if host.contains("youtu.be") {
            let pathComponents = url.pathComponents.filter { $0 != "/" }
            return pathComponents.first
        }
        
        if host.contains("youtube.com") {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let queryItems = components.queryItems,
            let videoID = queryItems.first(where: { $0.name == "v" })?.value {
                return videoID
            }
        }
        
        return nil
    }

    private func getWaveformURL(for videoID: String) -> URL {
        let waveformsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waveforms", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: waveformsDir, withIntermediateDirectories: true)
        return waveformsDir.appendingPathComponent("\(videoID).waveform")
    }
    
    // Update addDownload to preserve originalURL:
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
                
                var thumbnailFilename: String? = nil
                if let thumbPath = download.thumbnailPath {
                    thumbnailFilename = URL(fileURLWithPath: thumbPath).lastPathComponent
                }
                
                finalDownload = Download(
                    id: download.id,
                    name: download.name,
                    url: targetURL,
                    thumbnailPath: thumbnailFilename,
                    videoID: download.videoID,
                    source: download.source,
                    originalURL: download.originalURL  // ✅ PRESERVE THIS
                )
            } catch {
                print("❌ [DownloadManager] Failed to move file: \(error)")
                finalDownload = download
            }
        } else {
            if let thumbPath = download.thumbnailPath {
                let thumbnailFilename = URL(fileURLWithPath: thumbPath).lastPathComponent
                finalDownload = Download(
                    id: download.id,
                    name: download.name,
                    url: download.url,
                    thumbnailPath: thumbnailFilename,
                    videoID: download.videoID,
                    source: download.source,
                    originalURL: download.originalURL  // ✅ PRESERVE THIS
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
        
        timerLock.lock()
        if downloads[index].pendingDeletion {
            timerLock.unlock()
            cancelDeletion(download)
            return
        }
        timerLock.unlock()
        
        downloads[index].pendingDeletion = true
        objectWillChange.send()
        
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.confirmDeletion(download, onDelete: onDelete)
        }
        timerLock.lock()
        deletionTimers[download.id] = timer
        timerLock.unlock()
    }
    
    func cancelDeletion(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }) else { return }
        
        downloads[index].pendingDeletion = false

        timerLock.lock()
        deletionTimers[download.id]?.invalidate()
        deletionTimers.removeValue(forKey: download.id)
        timerLock.unlock()

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
        timerLock.lock()
        deletionTimers.removeValue(forKey: download.id)
        timerLock.unlock()
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
    
    // ✅ ADD THIS METHOD
    func getDownloadedFileURL(for videoID: String) -> URL? {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // Check common audio file extensions
        let extensions = ["m4a", "mp3", "wav", "aac"]
        
        for ext in extensions {
            let fileURL = documentsDir.appendingPathComponent("\(videoID).\(ext)")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
        }
        
        // Search through downloads array instead
        return downloads.first(where: { $0.url.lastPathComponent.contains(videoID) })?.url
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
                    source: loadedDownloads[i].source,
                    originalURL: loadedDownloads[i].originalURL  // Preserve originalURL
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
    // Add this method to DownloadManager class:
    func redownload(_ download: Download, onOldDeleted: @escaping () -> Void) {
        guard let originalURL = download.originalURL else {
            print("❌ [DownloadManager] No original URL stored for redownload")
            return
        }
        
        guard let videoID = download.videoID else {
            print("❌ [DownloadManager] No videoID for redownload")
            return
        }
        
        print("🔄 [DownloadManager] Redownloading from: \(originalURL)")
        
        // Start the new download
        startBackgroundDownload(
            url: originalURL,
            videoID: videoID,
            source: download.source,
            title: "Redownloading..."
        )
        
        // Mark old one for deletion (will auto-delete in 5 seconds)
        markForDeletion(download) { deletedDownload in
            onOldDeleted()
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