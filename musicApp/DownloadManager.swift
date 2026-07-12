import Foundation
import SwiftUI
import AVFoundation

class DownloadManager: ObservableObject {
    @Published var downloads: [Download] = [] {
        didSet {
            _sortedDownloadsCache = nil
        }
    }
    @Published var activeDownloads: [ActiveDownload] = []
    @Published var failedDownloads: [FailedDownload] = []
    
    // NEW: most recently completed download for UI prompt
    @Published var completedDownloadForPlaylistPrompt: Download? = nil

    private var isBatchDownloading = false
    
    private var deletionTimers: [UUID: Timer] = [:]
    private let timerLock = NSLock()
    private var updateDebounceTimer: Timer?
    
    weak var audioPlayer: AudioPlayerManager?
    
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
    private let playlistQueue = PlaylistDownloadQueue()
    
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
        validateAndFixThumbnails()
    }
    
    // Neutralize song names by removing formatting characters
    func neutralizeName(_ name: String) -> String {
        var cleaned = name
        
        // Remove common markdown/formatting characters
        cleaned = cleaned.replacingOccurrences(of: "_", with: " ")  // Underscores (italic in markdown)
        cleaned = cleaned.replacingOccurrences(of: "*", with: "")   // Asterisks (bold in markdown)
        cleaned = cleaned.replacingOccurrences(of: "~", with: "")   // Tildes (strikethrough)
        cleaned = cleaned.replacingOccurrences(of: "`", with: "")   // Backticks (code)
        cleaned = cleaned.replacingOccurrences(of: "#", with: "")   // Hashes (headers)
        
        // Remove Unicode mathematical alphanumeric symbols (used for styled text)
        // These are often used by YouTube/social media for bold, italic, etc.
        let unicodeFontRanges: [(UInt32, UInt32)] = [
            (0x1D400, 0x1D7FF),  // Mathematical Alphanumeric Symbols (bold, italic, script, etc.)
            (0x1D00, 0x1D7F),    // Phonetic Extensions
            (0x2100, 0x214F),    // Letterlike Symbols
        ]
        
        var neutralized = ""
        for scalar in cleaned.unicodeScalars {
            var shouldKeep = true
            
            // Check if character is in a fancy font range
            for (start, end) in unicodeFontRanges {
                if scalar.value >= start && scalar.value <= end {
                    // Try to convert fancy characters to normal ASCII
                    // Mathematical Bold (0x1D400-0x1D419 for A-Z, 0x1D41A-0x1D433 for a-z)
                    if scalar.value >= 0x1D400 && scalar.value <= 0x1D419 {
                        neutralized.append(Character(UnicodeScalar(scalar.value - 0x1D400 + 0x41)!)) // A-Z
                    } else if scalar.value >= 0x1D41A && scalar.value <= 0x1D433 {
                        neutralized.append(Character(UnicodeScalar(scalar.value - 0x1D41A + 0x61)!)) // a-z
                    }
                    // Mathematical Italic (0x1D434-0x1D467)
                    else if scalar.value >= 0x1D434 && scalar.value <= 0x1D44D {
                        neutralized.append(Character(UnicodeScalar(scalar.value - 0x1D434 + 0x41)!)) // A-Z
                    } else if scalar.value >= 0x1D44E && scalar.value <= 0x1D467 {
                        neutralized.append(Character(UnicodeScalar(scalar.value - 0x1D44E + 0x61)!)) // a-z
                    }
                    // Mathematical Bold Italic (0x1D468-0x1D49B)
                    else if scalar.value >= 0x1D468 && scalar.value <= 0x1D481 {
                        neutralized.append(Character(UnicodeScalar(scalar.value - 0x1D468 + 0x41)!)) // A-Z
                    } else if scalar.value >= 0x1D482 && scalar.value <= 0x1D49B {
                        neutralized.append(Character(UnicodeScalar(scalar.value - 0x1D482 + 0x61)!)) // a-z
                    }
                    // Add more mappings as needed...
                    shouldKeep = false
                    break
                }
            }
            
            if shouldKeep {
                neutralized.append(Character(scalar))
            }
        }
        
        cleaned = neutralized
        
        // Remove multiple consecutive spaces and trim
        cleaned = cleaned.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        
        return cleaned
    }
    // MARK: - Playlist Download Support

    /// Detects if URL is a playlist and returns (source, playlistID)
    func detectPlaylist(from urlString: String) -> (source: DownloadSource, playlistID: String, isPlaylist: Bool)? {
        guard let url = URL(string: urlString) else { return nil }
        let host = url.host?.lowercased() ?? ""
        
        // YouTube Playlist
        if host.contains("youtube.com") || host.contains("youtu.be") {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let queryItems = components.queryItems,
            let listID = queryItems.first(where: { $0.name == "list" })?.value {
                return (.youtube, listID, true)
            }
        }
        
        // Spotify Playlist or Album
        if host.contains("spotify.com") {
            let pathComponents = url.pathComponents.filter { $0 != "/" }
            
            if let playlistIndex = pathComponents.firstIndex(of: "playlist"),
            playlistIndex + 1 < pathComponents.count {
                var playlistID = pathComponents[playlistIndex + 1]
                if let queryIndex = playlistID.firstIndex(of: "?") {
                    playlistID = String(playlistID[..<queryIndex])
                }
                return (.spotify, playlistID, true)
            }
            
            if let albumIndex = pathComponents.firstIndex(of: "album"),
            albumIndex + 1 < pathComponents.count {
                var albumID = pathComponents[albumIndex + 1]
                if let queryIndex = albumID.firstIndex(of: "?") {
                    albumID = String(albumID[..<queryIndex])
                }
                return (.spotify, albumID, true)
            }
        }
        
        return nil
    }

    

    // MARK: - Playlist Download Queue (FIXED - Sequential, No Shared Callbacks)

    private actor PlaylistDownloadQueue {
        private var pendingTracks: [(videoID: String, title: String, url: String, source: DownloadSource)] = []
        private var isProcessing = false
        private var downloadedVideoIDs = Set<String>()  // Track what we've downloaded in this session
        
        func enqueue(tracks: [(videoID: String, title: String, url: String)], source: DownloadSource) {
            for track in tracks {
                // Skip if already queued or downloaded in this session
                if !downloadedVideoIDs.contains(track.videoID) {
                    pendingTracks.append((track.videoID, track.title, track.url, source))
                }
            }
        }
        
        func dequeue() -> (videoID: String, title: String, url: String, source: DownloadSource)? {
            guard !pendingTracks.isEmpty else { return nil }
            let track = pendingTracks.removeFirst()
            downloadedVideoIDs.insert(track.videoID)  // Mark as being processed
            return track
        }
        
        func setProcessing(_ value: Bool) {
            isProcessing = value
        }
        
        func isCurrentlyProcessing() -> Bool {
            return isProcessing
        }
        
        func getPendingCount() -> Int {
            return pendingTracks.count
        }
        
    }


    /// Downloads all tracks from a playlist - queues them and processes ONE AT A TIME
    func downloadPlaylist(url: String, source: DownloadSource, playlistID: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                let tracks: [(videoID: String, title: String, url: String)]
                
                if source == .youtube {
                    tracks = try await self.fetchYouTubePlaylistTracks(playlistID: playlistID)
                } else {
                    tracks = try await self.fetchSpotifyPlaylistTracks(playlistID: playlistID, originalURL: url)
                }
                
                print("📋 [Playlist] Found \(tracks.count) tracks")
                
                // Filter out duplicates that are already downloaded
                var tracksToQueue: [(videoID: String, title: String, url: String)] = []
                for track in tracks {
                    if self.findDuplicateByVideoID(videoID: track.videoID, source: source) == nil {
                        tracksToQueue.append(track)
                    } else {
                        #if DEBUG
                        print("⏭️ [Playlist] Skipping already-downloaded: \(track.title)")
                        #endif
                    }
                }
                
                guard !tracksToQueue.isEmpty else {
                    print("✅ [Playlist] All tracks already downloaded")
                    return
                }
                
                // Add to queue
                await self.playlistQueue.enqueue(tracks: tracksToQueue, source: source)
                print("📋 [Playlist] Queued \(tracksToQueue.count) new tracks")
                
                // Start processing if not already running
                if await !self.playlistQueue.isCurrentlyProcessing() {
                    await self.processPlaylistQueueSequentially()
                }
                
            } catch {
                print("❌ [Playlist] Failed to fetch playlist: \(error)")
            }
        }
    }

    // MARK: - Sequential Queue Processor (ONE AT A TIME)

    private func processPlaylistQueueSequentially() async {
        // Prevent multiple processors
        guard await !playlistQueue.isCurrentlyProcessing() else { return }
        await playlistQueue.setProcessing(true)
        
        let failedCountBefore = failedDownloads.count
        
        // Suppress per-track playlist prompts during batch
        await MainActor.run { self.isBatchDownloading = true }
        
        defer {
            Task {
                await self.playlistQueue.setProcessing(false)
                await MainActor.run { self.isBatchDownloading = false }
            }
        }
        
        while let track = await playlistQueue.dequeue() {
            let pending = await playlistQueue.getPendingCount()
            print("📥 [Queue] Starting download (\(pending) remaining): \(track.title)")
            
            // Check duplicate one more time right before download
            if findDuplicateByVideoID(videoID: track.videoID, source: track.source) != nil {
                print("⏭️ [Queue] Skipping duplicate: \(track.title)")
                continue
            }
            
            // Download this ONE track completely before moving to the next
            await downloadSingleTrackFromQueue(
                url: track.url,
                videoID: track.videoID,
                source: track.source,
                title: track.title
            )
        }
        
        let newFailures = failedDownloads.count - failedCountBefore
        if newFailures > 0 {
            print("⚠️ [Playlist] Finished with \(newFailures) failed track(s)")
        } else {
            print("✅ [Playlist] All downloads complete")
        }
    }

    // MARK: - Download Single Track (Self-Contained, No Shared Callbacks)

    private func downloadSingleTrackFromQueue(url: String, videoID: String, source: DownloadSource, title: String) async {
        // Create unique ID for this specific download
        let downloadID = UUID()
        
        // ✅ CRITICAL: Store the videoID locally so it doesn't get lost
        let originalVideoID = videoID
        
        // Create and show the active download banner
        let activeDownload = ActiveDownload(id: downloadID, videoID: originalVideoID, title: title, progress: 0.0)
        await MainActor.run {
            self.activeDownloads.append(activeDownload)
        }
        
        // Helper to update this specific download's banner
        func updateBanner(title: String, progress: Double) async {
            await MainActor.run {
                if let index = self.activeDownloads.firstIndex(where: { $0.id == downloadID }) {
                    self.activeDownloads[index].title = title
                    self.activeDownloads[index].progress = progress
                    self.notifyChange()
                }
            }
        }
        
        // Helper to remove this specific banner
        func removeBanner() async {
            await MainActor.run {
                self.activeDownloads.removeAll { $0.id == downloadID }
            }
        }
        
        do {
            var finalURL = url
            var finalVideoID = originalVideoID  // ✅ Use the captured original
            var spotifyTitle: String? = nil
            var youtubeSearchQuery: String? = nil
            
            // Handle Spotify conversion
            if source == .spotify {
                await updateBanner(title: "\(title)", progress: 0.2)
                
                let (convertedURL, trackInfo, searchQuery) = try await self.convertSpotifyToYouTube(spotifyURL: url)
                finalURL = convertedURL
                spotifyTitle = trackInfo
                youtubeSearchQuery = searchQuery
                
                if let extractedID = self.extractYouTubeID(from: finalURL) {
                    finalVideoID = extractedID
                }
                
                await updateBanner(title: "Downloading", progress: 0.4)
            } else {
                await updateBanner(title: "\(title)", progress: 0.3)
            }
            
            // ✅ CRITICAL: Store finalVideoID before download so it doesn't change
            let downloadVideoID = finalVideoID
            
            // Download the audio file — yt-dlp gives us the proper title from YouTube
            let (fileURL, downloadedTitle) = try await EmbeddedPython.shared.downloadAudio(url: finalURL, videoID: downloadVideoID)
            
            await updateBanner(title: "Processing: \(downloadedTitle)", progress: 0.7)
            
            await updateBanner(title: "Fetching thumbnail", progress: 0.85)
            
            // ✅ CRITICAL: Use the stored downloadVideoID, NOT the original videoID parameter
            // This ensures we fetch the thumbnail for the CORRECT video (YouTube video after Spotify conversion)
            print("🖼️ [Queue] Fetching thumbnail for videoID: \(downloadVideoID)")
            let thumbnailPath = await self.fetchThumbnailWithRetries(videoID: downloadVideoID, attempts: 5)
            
            if thumbnailPath != nil {
                print("✅ [Queue] Thumbnail fetched successfully")
            } else {
                print("⚠️ [Queue] No thumbnail found for videoID: \(downloadVideoID)")
            }
            
            // Always use the YouTube video title (yt-dlp provides it)
            let cleanedTitle = self.neutralizeName(downloadedTitle)
            
            // ✅ CRITICAL: Use downloadVideoID (the actual YouTube video ID) for the Download object
            let download = Download(
                name: cleanedTitle,
                url: fileURL,
                thumbnailPath: thumbnailPath?.path,
                videoID: downloadVideoID,  // ✅ Must match the thumbnail's videoID
                source: source,
                originalURL: url,
                spotifyTitle: spotifyTitle,
                youtubeSearchQuery: youtubeSearchQuery ?? (source == .youtube ? title : nil),
                youtubeURL: finalURL
            )
            
            // Remove banner and add to downloads
            await MainActor.run {
                self.activeDownloads.removeAll { $0.id == downloadID }
                self.addDownload(download)
                
                // Prompt user to add to playlist (only for single downloads, not batch)
                if !self.isBatchDownloading {
                    // Small delay to let any dismissing sheets finish
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.completedDownloadForPlaylistPrompt = download
                    }
                }
            }

            print("✅ [Queue] Saved: \(cleanedTitle) (videoID: \(downloadVideoID))")
            
        } catch {
            print("❌ [Queue] Failed: \(title) - \(error)")
            let failed = FailedDownload(
                title: title,
                url: url,
                source: source,
                error: error.localizedDescription,
                timestamp: Date()
            )
            await MainActor.run {
                self.failedDownloads.append(failed)
            }
            await removeBanner()
        }
    }



    // MARK: - YouTube Playlist Extraction

    private func fetchYouTubePlaylistTracks(playlistID: String) async throws -> [(videoID: String, title: String, url: String)] {
        return try await withCheckedThrowingContinuation { continuation in
            let resultFilePath = NSTemporaryDirectory() + "yt_playlist_\(UUID().uuidString).json"
            let script = generateYouTubePlaylistScript(playlistID: playlistID, resultFilePath: resultFilePath)
            
            DispatchQueue.global(qos: .userInitiated).async {
                guard EmbeddedPython.shared.executePythonScript(script) else {
                    continuation.resume(throwing: NSError(domain: "YouTubePlaylist", code: -1, 
                        userInfo: [NSLocalizedDescriptionKey: "Failed to execute playlist script"]))
                    return
                }
                
                guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: resultFilePath)),
                    let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continuation.resume(throwing: NSError(domain: "YouTubePlaylist", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to read playlist result"]))
                    return
                }
                
                try? FileManager.default.removeItem(atPath: resultFilePath)
                
                guard let success = json["success"] as? Bool, success,
                    let tracksArray = json["tracks"] as? [[String: String]] else {
                    let error = json["error"] as? String ?? "Unknown error"
                    continuation.resume(throwing: NSError(domain: "YouTubePlaylist", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: error]))
                    return
                }
                
                let tracks = tracksArray.compactMap { track -> (videoID: String, title: String, url: String)? in
                    guard let videoID = track["video_id"],
                        let title = track["title"] else { return nil }
                    let url = "https://www.youtube.com/watch?v=\(videoID)"
                    return (videoID, title, url)
                }
                
                continuation.resume(returning: tracks)
            }
        }
    }

    private func generateYouTubePlaylistScript(playlistID: String, resultFilePath: String) -> String {
        return """
        import json
        import re
        import requests

        def get_playlist_videos(playlist_id):
            try:
                url = f"https://www.youtube.com/playlist?list={playlist_id}"
                headers = {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                    "Accept-Language": "en-US,en;q=0.9"
                }
                
                response = requests.get(url, headers=headers, timeout=30)
                if response.status_code != 200:
                    return None, f"HTTP {response.status_code}"
                
                html = response.text
                
                # Extract video IDs and titles from playlist page
                # Pattern matches: {"videoId":"XXXXXXXXXXX","title":{"runs":[{"text":"Title"}]
                pattern = r'"videoId":"([a-zA-Z0-9_-]{11})".*?"title":\\{"runs":\\[\\{"text":"([^"]+)"'
                matches = re.findall(pattern, html)
                
                if not matches:
                    # Fallback: just extract video IDs
                    video_ids = list(set(re.findall(r'"videoId":"([a-zA-Z0-9_-]{11})"', html)))
                    matches = [(vid, f"Track {i+1}") for i, vid in enumerate(video_ids)]
                
                # Remove duplicates while preserving order
                seen = set()
                unique_tracks = []
                for video_id, title in matches:
                    if video_id not in seen:
                        seen.add(video_id)
                        unique_tracks.append({"video_id": video_id, "title": title})
                
                return unique_tracks, None
                
            except Exception as e:
                return None, str(e)

        playlist_id = r'''\(playlistID)'''
        result = {}

        tracks, error = get_playlist_videos(playlist_id)
        if tracks:
            result = {"success": True, "tracks": tracks}
        else:
            result = {"success": False, "error": error or "Failed to fetch playlist"}

        with open(r'''\(resultFilePath)''', 'w', encoding='utf-8') as f:
            json.dump(result, f)
        """
    }

    // MARK: - Spotify Playlist Extraction

    private func fetchSpotifyPlaylistTracks(playlistID: String, originalURL: String) async throws -> [(videoID: String, title: String, url: String)] {
        return try await withCheckedThrowingContinuation { continuation in
            let resultFilePath = NSTemporaryDirectory() + "spotify_playlist_\(UUID().uuidString).json"
            
            // Detect if it's an album or playlist from the URL
            let isAlbum = originalURL.contains("/album/")
            let script = generateSpotifyPlaylistScript(playlistID: playlistID, isAlbum: isAlbum, resultFilePath: resultFilePath)
            
            DispatchQueue.global(qos: .userInitiated).async {
                guard EmbeddedPython.shared.executePythonScript(script) else {
                    continuation.resume(throwing: NSError(domain: "SpotifyPlaylist", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to execute Spotify playlist script"]))
                    return
                }
                
                guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: resultFilePath)),
                    let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continuation.resume(throwing: NSError(domain: "SpotifyPlaylist", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to read Spotify playlist result"]))
                    return
                }
                
                try? FileManager.default.removeItem(atPath: resultFilePath)
                
                guard let success = json["success"] as? Bool, success,
                    let tracksArray = json["tracks"] as? [[String: String]] else {
                    let error = json["error"] as? String ?? "Unknown error"
                    continuation.resume(throwing: NSError(domain: "SpotifyPlaylist", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: error]))
                    return
                }
                
                let apiCount = json["count"] as? Int ?? -1
                print("📊 [Spotify API] Returned \(apiCount) tracks, parsed \(tracksArray.count) entries")
                
                let tracks = tracksArray.compactMap { track -> (videoID: String, title: String, url: String)? in
                    guard let trackID = track["track_id"],
                        let title = track["title"] else { return nil }
                    let url = "https://open.spotify.com/track/\(trackID)"
                    return (trackID, title, url)
                }
                
                continuation.resume(returning: tracks)
            }
        }
    }

    private func generateSpotifyPlaylistScript(playlistID: String, isAlbum: Bool, resultFilePath: String) -> String {
        return """
        import json
        import re
        import requests

        def get_spotify_playlist_tracks(playlist_id, is_album):
            try:
                # Use the Spotify EMBED endpoint — it's fully public (designed for
                # iframes on any website) and returns ALL tracks in a JSON blob
                # inside a <script id="__NEXT_DATA__"> tag. No auth needed.
                endpoint = "album" if is_album else "playlist"
                url = f"https://open.spotify.com/embed/{endpoint}/{playlist_id}"

                headers = {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                    "Accept-Language": "en-US,en;q=0.9",
                }

                resp = requests.get(url, headers=headers, timeout=30)
                if resp.status_code != 200:
                    return None, f"Spotify embed returned HTTP {resp.status_code}"

                html = resp.text

                # Extract the __NEXT_DATA__ JSON blob
                match = re.search(r'<script\\s+id="__NEXT_DATA__"[^>]*>(.+?)</script>', html, re.DOTALL)
                if not match:
                    return None, "Could not find __NEXT_DATA__ in embed page"

                data = json.loads(match.group(1))

                # Navigate to the track list inside the JSON structure
                # Structure: props -> pageProps -> state -> data -> entity -> trackList
                try:
                    entity = data["props"]["pageProps"]["state"]["data"]["entity"]
                except (KeyError, TypeError):
                    return None, "Unexpected embed JSON structure"

                track_list = entity.get("trackList", [])
                if not track_list:
                    return None, f"Embed returned 0 tracks"

                tracks = []
                seen = set()
                for item in track_list:
                    uri = item.get("uri", "")
                    # uri format: spotify:track:XXXXXXXXXXXXXXXXXXXX
                    parts = uri.split(":")
                    if len(parts) != 3 or parts[1] != "track":
                        continue
                    track_id = parts[2]
                    if track_id in seen:
                        continue
                    seen.add(track_id)

                    title = item.get("title", "Unknown")
                    subtitle = item.get("subtitle", "")
                    display = f"{subtitle} - {title}" if subtitle else title
                    tracks.append({"track_id": track_id, "title": display})

                if not tracks:
                    return None, "Parsed embed JSON but found no tracks"

                return tracks, None

            except Exception as e:
                return None, str(e)

        playlist_id = r'''\(playlistID)'''
        is_album = \(isAlbum ? "True" : "False")
        result = {}

        tracks, error = get_spotify_playlist_tracks(playlist_id, is_album)
        if tracks:
            result = {"success": True, "tracks": tracks, "count": len(tracks)}
        else:
            result = {"success": False, "error": error or "Failed to fetch playlist"}

        with open(r'''\(resultFilePath)''', 'w', encoding='utf-8') as f:
            json.dump(result, f)
        """
    }

    
    private func notifyChange() {
        updateDebounceTimer?.invalidate()
        updateDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    
    // Helper function to fetch thumbnail with retries (Swift 6 concurrency-safe)
    /// Guaranteed thumbnail fetch — tries every known YouTube thumbnail URL quality
    /// Returns the saved thumbnail file URL, or nil only if the video truly has no thumbnail.
    // FIXED: Saved as Thumbnails/<videoID>.jpg, not <audio filename>.jpg. The
    // audio filename is derived from the display title, and titles get reused
    // across DIFFERENT videos (title twins, renames, redownloads) — under that
    // key, the exists-short-circuit below silently handed a new song the
    // previous song's artwork, permanently. The videoID IS the artwork's
    // identity, so under this key the short-circuit is always correct.
    private func fetchThumbnailWithRetries(videoID: String, attempts: Int) async -> URL? {
        guard !videoID.isEmpty else { return nil }

        let thumbnailsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        let savePath = thumbnailsDir.appendingPathComponent("\(videoID).jpg")

        // If already exists and is valid, return immediately
        if FileManager.default.fileExists(atPath: savePath.path),
        let img = UIImage(contentsOfFile: savePath.path),
        img.size.width > 150 && img.size.height > 150 {
            return savePath
        }
        
        // All possible thumbnail URLs in quality order
        let thumbnailURLs: [String] = [
            "https://img.youtube.com/vi/\(videoID)/maxresdefault.jpg",
            "https://img.youtube.com/vi/\(videoID)/sddefault.jpg",
            "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/sddefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
            "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg",
            "https://img.youtube.com/vi/\(videoID)/0.jpg",
            "https://i.ytimg.com/vi/\(videoID)/0.jpg",
            "https://img.youtube.com/vi/\(videoID)/default.jpg",
        ]
        
        let minFileSize = 5_000       // 5KB (placeholders are ~1-2KB)
        let minWidth: CGFloat = 200
        let minHeight: CGFloat = 150
        
        for urlString in thumbnailURLs {
            guard let url = URL(string: urlString) else { continue }
            
            // Try each URL with up to 2 network attempts
            for networkAttempt in 1...2 {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    
                    guard let httpResponse = response as? HTTPURLResponse else { continue }
                    
                    // Non-200 = this quality doesn't exist
                    guard httpResponse.statusCode == 200 else {
                        break // try next URL
                    }
                    
                    // Skip tiny placeholder images
                    guard data.count >= minFileSize else {
                        print("⚠️ [Thumbnail] Placeholder (\(data.count) bytes): \(urlString)")
                        break // try next quality
                    }
                    
                    // Validate dimensions
                    guard let image = UIImage(data: data),
                        image.size.width >= minWidth,
                        image.size.height >= minHeight else {
                        print("⚠️ [Thumbnail] Too small from: \(urlString)")
                        break // placeholder, try next
                    }
                    
                    // Convert to JPEG for consistent format
                    let saveData: Data
                    if let jpegData = image.jpegData(compressionQuality: 0.92) {
                        saveData = jpegData
                    } else {
                        saveData = data
                    }
                    
                    // Save atomically
                    try saveData.write(to: savePath, options: .atomic)
                    
                    // Verify readable
                    if let _ = UIImage(contentsOfFile: savePath.path) {
                        print("✅ [Thumbnail] Saved \(Int(image.size.width))x\(Int(image.size.height)) (\(saveData.count / 1024)KB) from: \(urlString)")
                        return savePath
                    } else {
                        try? FileManager.default.removeItem(at: savePath)
                        continue // retry write
                    }
                    
                } catch {
                    if networkAttempt < 2 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        continue
                    }
                    break // move to next URL
                }
            }
        }
        
        // Last resort: yt-dlp extraction for edge cases (age-restricted, signed URLs)
        print("⚠️ [Thumbnail] All direct URLs failed for \(videoID), trying yt-dlp...")
        
        if let ytdlpResult = await fetchThumbnailViaYtdlp(videoID: videoID, savePath: savePath) {
            return ytdlpResult
        }
        
        print("❌ [Thumbnail] ALL methods failed for videoID: \(videoID)")
        return nil
    }

    /// Last-resort: Use yt-dlp to extract the actual thumbnail URL (handles signed/age-restricted)
    private func fetchThumbnailViaYtdlp(videoID: String, savePath: URL) async -> URL? {
        return await withCheckedContinuation { continuation in
            let resultFilePath = NSTemporaryDirectory() + "thumb_\(videoID)_\(UUID().uuidString).json"
            
            let script = """
            import json
            import yt_dlp
            
            result = {}
            try:
                ydl_opts = {
                    'quiet': True,
                    'no_warnings': True,
                    'skip_download': True,
                    'noplaylist': True,
                    'extractor_args': {
                        'youtube': {
                            'player_client': ['ios', 'android'],
                        }
                    },
                }
                
                with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                    info = ydl.extract_info(f'https://www.youtube.com/watch?v=\(videoID)', download=False)
                    thumbnails = info.get('thumbnails', [])
                    
                    # Prefer jpg/png over webp
                    jpg_thumbnails = [t for t in thumbnails if t.get('url', '').split('?')[0].endswith(('.jpg', '.png'))]
                    if not jpg_thumbnails:
                        jpg_thumbnails = thumbnails
                    
                    # Sort by resolution descending
                    jpg_thumbnails.sort(key=lambda t: t.get('width', 0) * t.get('height', 0), reverse=True)
                    
                    if jpg_thumbnails:
                        result = {'success': True, 'url': jpg_thumbnails[0]['url']}
                    else:
                        result = {'success': False, 'error': 'No thumbnails found'}
            except Exception as e:
                result = {'success': False, 'error': str(e)}
            
            with open(r'''\(resultFilePath)''', 'w', encoding='utf-8') as f:
                json.dump(result, f)
            """
            
            DispatchQueue.global(qos: .userInitiated).async {
                guard EmbeddedPython.shared.executePythonScript(script) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                defer { try? FileManager.default.removeItem(atPath: resultFilePath) }
                
                guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: resultFilePath)),
                    let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                    let success = json["success"] as? Bool, success,
                    let thumbnailURLString = json["url"] as? String,
                    let thumbnailURL = URL(string: thumbnailURLString) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Download the thumbnail from the extracted URL
                Task {
                    do {
                        let (data, response) = try await URLSession.shared.data(from: thumbnailURL)
                        
                        guard let httpResponse = response as? HTTPURLResponse,
                            httpResponse.statusCode == 200,
                            data.count > 5000,
                            let image = UIImage(data: data),
                            image.size.width >= 150 else {
                            continuation.resume(returning: nil)
                            return
                        }
                        
                        // Convert to JPEG
                        let saveData: Data
                        if let jpegData = image.jpegData(compressionQuality: 0.92) {
                            saveData = jpegData
                        } else {
                            saveData = data
                        }
                        
                        try saveData.write(to: savePath, options: .atomic)
                        print("✅ [Thumbnail] Saved via yt-dlp: \(Int(image.size.width))x\(Int(image.size.height))")
                        continuation.resume(returning: savePath)
                    } catch {
                        print("❌ [Thumbnail] yt-dlp URL download failed: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
    

    func renameDownload(_ download: Download, newName: String) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }) else {
            print("❌ [DownloadManager] Download not found in array")
            return
        }
        
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        // Use the URL from the actual downloads array (not the passed-in copy which may be stale)
        let currentDownload = downloads[index]
        let oldURL = currentDownload.url
        let fileExtension = oldURL.pathExtension
        let newFileName = "\(trimmedName).\(fileExtension)"
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newFileName)
        
        // If the name didn't actually change, skip file operations
        if oldURL.lastPathComponent == newURL.lastPathComponent {
            return
        }
        
        // Try to rename the file
        do {
            guard FileManager.default.fileExists(atPath: oldURL.path) else {
                print("❌ [DownloadManager] Source file doesn't exist at: \(oldURL.path)")
                return
            }
            
            // If file exists at new location, generate unique name
            var finalURL = newURL
            var counter = 1
            while FileManager.default.fileExists(atPath: finalURL.path) {
                finalURL = oldURL.deletingLastPathComponent().appendingPathComponent("\(trimmedName) (\(counter)).\(fileExtension)")
                counter += 1
            }
            
            try FileManager.default.moveItem(at: oldURL, to: finalURL)
            print("✅ [DownloadManager] File renamed from '\(oldURL.lastPathComponent)' to '\(finalURL.lastPathComponent)'")
            
            // Rename the thumbnail file if it exists
            let thumbnailsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Thumbnails", isDirectory: true)
            let oldThumbnailPath = thumbnailsDir.appendingPathComponent("\(oldURL.lastPathComponent).jpg")
            let newThumbnailPath = thumbnailsDir.appendingPathComponent("\(finalURL.lastPathComponent).jpg")
            
            var newThumbnailFilename: String? = currentDownload.thumbnailPath
            if FileManager.default.fileExists(atPath: oldThumbnailPath.path) {
                do {
                    try FileManager.default.moveItem(at: oldThumbnailPath, to: newThumbnailPath)
                    newThumbnailFilename = newThumbnailPath.lastPathComponent
                    print("✅ [DownloadManager] Thumbnail renamed")
                } catch {
                    print("⚠️ [DownloadManager] Failed to rename thumbnail: \(error.localizedDescription)")
                }
            }
            
            // Update the download with new name, URL, and thumbnail path
            downloads[index] = Download(
                id: currentDownload.id,
                name: trimmedName,
                url: finalURL,
                thumbnailPath: newThumbnailFilename,
                videoID: currentDownload.videoID,
                source: currentDownload.source,
                originalURL: currentDownload.originalURL,
                cropStartTime: currentDownload.cropStartTime,
                cropEndTime: currentDownload.cropEndTime
            )
            
            saveDownloads()
            notifyChange()
            
            // If this track is currently playing, update the AudioPlayerManager
            // Match by ID since URLs are value types and might be stale copies
            if let audioPlayer = self.audioPlayer,
               let currentTrack = audioPlayer.currentTrack,
               currentTrack.id == currentDownload.id {
                
                let updatedTrack = Track(
                    id: currentTrack.id,
                    name: trimmedName,
                    url: finalURL,
                    folderName: currentTrack.folderName
                )
                
                audioPlayer.currentTrack = updatedTrack
                audioPlayer.updateCurrentTrackURL(finalURL)
                
                if let playlistIndex = audioPlayer.currentPlaylist.firstIndex(where: { $0.id == currentTrack.id }) {
                    audioPlayer.currentPlaylist[playlistIndex] = updatedTrack
                }
                
                if let queueIndex = audioPlayer.queue.firstIndex(where: { $0.id == currentTrack.id }) {
                    audioPlayer.queue[queueIndex] = updatedTrack
                }
                
                print("✅ [DownloadManager] Updated currently playing track metadata and URL")
            }
            
        } catch {
            print("❌ [DownloadManager] Failed to rename file: \(error.localizedDescription)")
        }
    }
    
    // Update crop times for a track
    func updateCropTimes(for trackID: UUID, startTime: Double?, endTime: Double?) {
        // 1. Persist to the Download model (saved to disk)
        if let downloadIndex = downloads.firstIndex(where: { $0.id == trackID }) {
            downloads[downloadIndex].cropStartTime = startTime
            downloads[downloadIndex].cropEndTime = endTime
            saveDownloads()
            print("✅ [DownloadManager] Persisted crop times to disk for: \(downloads[downloadIndex].name)")
        }
        
        // 2. Update in AudioPlayer's in-memory state
        if let audioPlayer = self.audioPlayer {
            if let currentTrack = audioPlayer.currentTrack, currentTrack.id == trackID {
                var updatedTrack = currentTrack
                updatedTrack.cropStartTime = startTime
                updatedTrack.cropEndTime = endTime
                audioPlayer.currentTrack = updatedTrack
            }
            
            if let playlistIndex = audioPlayer.currentPlaylist.firstIndex(where: { $0.id == trackID }) {
                audioPlayer.currentPlaylist[playlistIndex].cropStartTime = startTime
                audioPlayer.currentPlaylist[playlistIndex].cropEndTime = endTime
            }
            
            if let queueIndex = audioPlayer.queue.firstIndex(where: { $0.id == trackID }) {
                audioPlayer.queue[queueIndex].cropStartTime = startTime
                audioPlayer.queue[queueIndex].cropEndTime = endTime
            }
            
            if let prevIndex = audioPlayer.previousQueue.firstIndex(where: { $0.id == trackID }) {
                audioPlayer.previousQueue[prevIndex].cropStartTime = startTime
                audioPlayer.previousQueue[prevIndex].cropEndTime = endTime
            }
        }
    }

    // ✅ ADD: Helper method to convert Spotify to YouTube
    private func convertSpotifyToYouTube(spotifyURL: String) async throws -> (youtubeURL: String, trackInfo: String?, searchQuery: String?) {
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
                
                let trackInfo = json["track_info"] as? String
                let searchQuery = json["search_query"] as? String
                continuation.resume(returning: (youtubeURL, trackInfo, searchQuery))
            }
        }
    }

    // Generate Python script for Spotify → YouTube conversion
    // Uses oEmbed API for the track title, then searches YouTube
    private func generateSpotifyConversionScript(spotifyURL: String, resultFilePath: String) -> String {
        let cleanURL = spotifyURL.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        
        return """
        import sys
        import json
        import requests
        import re
        
        def get_spotify_title(spotify_url):
            try:
                oembed_url = f"https://open.spotify.com/oembed?url={spotify_url}"
                response = requests.get(oembed_url, timeout=10)
                if response.status_code == 200:
                    data = response.json()
                    return data.get("title")
            except Exception as e:
                print(f"oEmbed failed: {e}")
            return None
        
        def search_youtube(query):
            try:
                query = query.replace(' ', '+')
                url = f"https://www.youtube.com/results?search_query={query}"
                headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
                
                response = requests.get(url, headers=headers, timeout=10)
                if response.status_code != 200:
                    return None
                
                video_ids = re.findall(r"watch\\?v=(\\S{11})", response.text)
                if video_ids:
                    return f"https://www.youtube.com/watch?v={video_ids[0]}"
                return None
            except Exception as e:
                print(f"Error searching YouTube: {e}")
                return None
        
        # Main execution
        spotify_url = r'''\(cleanURL)'''
        result = {}
        
        try:
            title = get_spotify_title(spotify_url)
            if not title:
                result = {'success': False, 'error': 'Could not get track info from Spotify'}
            else:
                print(f"Found track: {title}")
                youtube_url = search_youtube(title)
                if youtube_url:
                    result = {'success': True, 'youtube_url': youtube_url, 'track_info': title, 'search_query': title}
                else:
                    result = {'success': False, 'error': f'Could not find YouTube video for: {title}'}
        except Exception as e:
            result = {'success': False, 'error': str(e)}
        
        with open(r'''\(resultFilePath)''', 'w', encoding='utf-8') as f:
            json.dump(result, f)
        """
    }

    // Helper to extract YouTube video ID
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
    
    // MARK: - Start Background Download (single track entry point)

    func startBackgroundDownload(url: String, videoID: String, source: DownloadSource, title: String) {
        // Only treat as a playlist if there's NO specific video/track ID in the URL.
        // YouTube: has `list=` but NOT `v=` → it's a bare playlist link
        // Spotify: has /playlist/ or /album/ but NOT /track/ → it's a playlist link
        let isBarePlaylst: Bool = {
            guard let u = URL(string: url),
                  let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return false }
            let host = u.host?.lowercased() ?? ""
            if host.contains("youtube.com") || host.contains("youtu.be") {
                let hasVideo = comps.queryItems?.contains(where: { $0.name == "v" }) == true
                let hasList  = comps.queryItems?.contains(where: { $0.name == "list" }) == true
                return hasList && !hasVideo   // bare playlist only
            }
            if host.contains("spotify.com") {
                let path = u.pathComponents
                let isTrack = path.contains("track")
                let isList  = path.contains("playlist") || path.contains("album")
                return isList && !isTrack     // bare playlist/album only
            }
            return false
        }()

        if isBarePlaylst,
           let (detectedSource, playlistID, _) = detectPlaylist(from: url) {
            downloadPlaylist(url: url, source: detectedSource, playlistID: playlistID)
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await self.downloadSingleTrackFromQueue(
                url: url,
                videoID: videoID,
                source: source,
                title: title
            )
        }
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
                    originalURL: download.originalURL,
                    cropStartTime: download.cropStartTime,
                    cropEndTime: download.cropEndTime
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
                    originalURL: download.originalURL,
                    cropStartTime: download.cropStartTime,
                    cropEndTime: download.cropEndTime
                )
            }
        }
        
        downloads.append(finalDownload)
        saveDownloads()
        notifyChange()
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
        notifyChange()
        
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

        notifyChange()
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
        
        if let thumbPath = download.resolvedThumbnailPath {
            do {
                if FileManager.default.fileExists(atPath: thumbPath) {
                    try FileManager.default.removeItem(atPath: thumbPath)
                    print("✅ [DownloadManager] Deleted thumbnail: \((thumbPath as NSString).lastPathComponent)")
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
            #if DEBUG
            print("🔍 [Duplicate] Found exact match by videoID: \(existing.name)")
            #endif
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
                #if DEBUG
                print("🔍 [Duplicate] Found match by cleaned videoID: \(existing.name)")
                #endif
                return existing
            }

            if let existing = downloads.first(where: { download in
                guard download.source == .youtube, !download.pendingDeletion else { return false }
                let filename = download.url.lastPathComponent
                return filename.contains(videoID)
            }) {
                #if DEBUG
                print("🔍 [Duplicate] Found match by filename: \(existing.name)")
                #endif
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
                #if DEBUG
                print("🔍 [Duplicate] Found Spotify match: \(existing.name)")
                #endif
                return existing
            }
        }

        #if DEBUG
        print("✅ [Duplicate] No duplicate found for videoID: \(videoID)")
        #endif
        return nil
    }
    
    private func saveDownloads() {
        PerformanceMonitor.shared.start("DownloadManager_Save")
        defer { PerformanceMonitor.shared.end("DownloadManager_Save") }
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
        PerformanceMonitor.shared.start("DownloadManager_Load")
        defer { PerformanceMonitor.shared.end("DownloadManager_Load") }
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
                    originalURL: loadedDownloads[i].originalURL,
                    cropStartTime: loadedDownloads[i].cropStartTime,
                    cropEndTime: loadedDownloads[i].cropEndTime
                )
                
                loadedDownloads[i].pendingDeletion = false
                
                #if DEBUG
                if !FileManager.default.fileExists(atPath: correctPath.path) {
                    print("⚠️ [DownloadManager] Missing file: \(filename) at \(correctPath.path)")
                } else {
                    print("✅ [DownloadManager] Found file: \(filename)")
                }
                #endif
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

    // ✅ FIXED: Proper redownload with banner and validation
    func redownload(_ download: Download, onOldDeleted: @escaping () -> Void) {
        guard let originalURL = download.originalURL else {
            print("❌ [DownloadManager] No original URL stored for redownload")
            return
        }
        
        guard let videoID = download.videoID else {
            print("❌ [DownloadManager] No videoID for redownload")
            return
        }
        
        print("🔄 [DownloadManager] Starting redownload for: \(download.name)")
        
        // Store reference to old download
        let oldDownloadID = download.id
        let oldFileURL = download.url
        let oldThumbnailPath = download.thumbnailPath
        
        // Create active download entry (this shows the banner)
        let activeDownload = ActiveDownload(
            id: UUID(),
            videoID: videoID,
            title: "Redownloading \(download.name)...",
            progress: 0.0
        )
        
        DispatchQueue.main.async {
            self.activeDownloads.append(activeDownload)
        }
        
        let targetDownloadID = activeDownload.id
        
        // Set up title callback
        EmbeddedPython.shared.onTitleFetched = { [weak self] callbackVideoID, callbackTitle in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let index = self.activeDownloads.firstIndex(where: { $0.id == targetDownloadID }) {
                    self.activeDownloads[index] = ActiveDownload(
                        id: self.activeDownloads[index].id,
                        videoID: callbackVideoID,
                        title: "Redownloading \(callbackTitle)...",
                        progress: 0.5
                    )
                    self.notifyChange()
                }
            }
        }
        
        // Start download in background
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                // Download new file (already goes to Music directory)
                let (newFileURL, downloadedTitle) = try await EmbeddedPython.shared.downloadAudio(
                    url: originalURL,
                    videoID: videoID
                )
                
                // Get thumbnail with retries (avoiding var capture in concurrent code)
                let thumbnailPath = await self.fetchThumbnailWithRetries(videoID: videoID, attempts: 5)
                
                // Validate the new file is playable
                let testFile = try AVAudioFile(forReading: newFileURL)
                guard testFile.length > 0 else {
                    throw NSError(
                        domain: "DownloadManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Downloaded file is empty"]
                    )
                }
                
                print("✅ [DownloadManager] New file validated: \(newFileURL.lastPathComponent)")
                
                await MainActor.run {
                    // Remove from active downloads
                    self.activeDownloads.removeAll { $0.id == targetDownloadID }
                    
                    // Find and update the existing download entry IN-PLACE
                    if let index = self.downloads.firstIndex(where: { $0.id == oldDownloadID }) {
                        // ✅ FIX: Check if file is already in correct location
                        let isAlreadyInMusicDir = newFileURL.deletingLastPathComponent() == self.musicDirectory
                        
                        let finalURL: URL
                        if isAlreadyInMusicDir {
                            // File is already where it needs to be, just use it
                            finalURL = newFileURL
                            print("✅ [DownloadManager] New file already in Music directory")
                        } else {
                            // Need to move to Music directory
                            let targetURL = self.musicDirectory.appendingPathComponent(newFileURL.lastPathComponent)
                            
                            do {
                                // Remove target if exists
                                if FileManager.default.fileExists(atPath: targetURL.path) {
                                    try FileManager.default.removeItem(at: targetURL)
                                }
                                
                                // Move new file
                                try FileManager.default.moveItem(at: newFileURL, to: targetURL)
                                finalURL = targetURL
                                print("✅ [DownloadManager] Moved new file to Music directory")
                            } catch {
                                print("❌ [DownloadManager] Failed to move new file: \(error)")
                                // Use the file where it is
                                finalURL = newFileURL
                            }
                        }
                        
                        // Update the download entry with new file URL (keeps same ID!)
                        self.downloads[index] = Download(
                            id: oldDownloadID,  // ✅ KEEP SAME ID
                            name: downloadedTitle,
                            url: finalURL,  // New file location
                            thumbnailPath: thumbnailPath?.path,
                            videoID: videoID,
                            source: download.source,
                            originalURL: originalURL
                        )
                        
                        self.saveDownloads()
                        self.notifyChange()
                        
                        print("✅ [DownloadManager] Updated download entry with new file: \(finalURL.path)")
                        
                        // NOW mark old file for deletion (only if it's different from new file)
                        if oldFileURL != finalURL && FileManager.default.fileExists(atPath: oldFileURL.path) {
                            // Same videoID → the new record shares the old
                            // "<videoID>.jpg" thumbnail; don't delete it with
                            // the old audio file.
                            let sharesThumbnail = oldThumbnailPath != nil
                                && oldThumbnailPath == thumbnailPath?.lastPathComponent
                            // Create a temporary download object just for deletion
                            let oldDownloadForDeletion = Download(
                                id: UUID(),  // Different ID so it doesn't conflict
                                name: "Old version",
                                url: oldFileURL,
                                thumbnailPath: sharesThumbnail ? nil : oldThumbnailPath,
                                videoID: nil,
                                source: download.source
                            )
                            
                            self.markForDeletion(oldDownloadForDeletion) { _ in
                                onOldDeleted()
                            }
                            
                            print("🗑️ [DownloadManager] Scheduled old file for deletion: \(oldFileURL.lastPathComponent)")
                        } else {
                            print("ℹ️ [DownloadManager] Old file same as new file or already deleted, skipping deletion")
                            onOldDeleted()
                        }
                        
                    } else {
                        print("⚠️ [DownloadManager] Could not find original download entry")
                    }
                }
                
            } catch {
                print("❌ [DownloadManager] Redownload failed: \(error)")
                
                await MainActor.run {
                    self.activeDownloads.removeAll { $0.id == targetDownloadID }
                }
            }
        }
    }
    
    // Backoff before retrying a thumbnail that exhausted every URL/attempt —
    // matches LyricsService's notFoundRetryMs pattern, so a permanently
    // unfetchable thumbnail (deleted/private video) doesn't repeat the same
    // up-to-14-request chain on every single cold launch.
    private static let thumbnailRetryBackoffMs: Int64 = 7 * 24 * 3600 * 1000

    private func shouldRetryThumbnail(_ download: Download) -> Bool {
        guard let failedAtMs = download.thumbnailFetchFailedAtMs else { return true }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return nowMs - failedAtMs > Self.thumbnailRetryBackoffMs
    }

    private func recordThumbnailFetchFailed(downloadID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let idx = self.downloads.firstIndex(where: { $0.id == downloadID }) else { return }
            self.downloads[idx].thumbnailFetchFailedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            self.saveDownloads()
        }
    }

    // A videoID-keyed thumbnail landed on disk — point the record at it.
    // Main queue for the same reason as recordThumbnailFetchFailed above.
    private func adoptKeyedThumbnail(downloadID: UUID, filename: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let idx = self.downloads.firstIndex(where: { $0.id == downloadID }) else { return }
            guard self.downloads[idx].thumbnailPath != filename else { return }
            self.downloads[idx].thumbnailPath = filename
            self.downloads[idx].thumbnailFetchFailedAtMs = nil
            self.saveDownloads()
            self.notifyChange()
        }
    }

    // FIXED: Validate and regenerate missing thumbnails on boot.
    // Also migrates records to the videoID-keyed scheme: legacy thumbnails
    // were keyed by audio filename, a reusable key under which a track could
    // inherit a DIFFERENT song's artwork (see fetchThumbnailWithRetries).
    // Every record with a videoID converges on "<videoID>.jpg" — adopted
    // directly when the file already exists, refetched from its own videoID
    // otherwise. Legacy art keeps displaying until its replacement lands.
    private func validateAndFixThumbnails() {
        #if DEBUG
        print("🔍 [DownloadManager] Validating thumbnails...")
        #endif
        var needsSave = false

        let thumbnailsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)

        for (index, download) in downloads.enumerated() {
            // FIXED: Migrate old absolute paths to just filename
            if let oldPath = download.thumbnailPath, oldPath.contains("/") {
                downloads[index].thumbnailPath = (oldPath as NSString).lastPathComponent
                needsSave = true
            }

            // No videoID → nothing to fetch from; the record keeps whatever
            // legacy thumbnail it has.
            guard let videoID = download.videoID, !videoID.isEmpty else { continue }

            let keyedFilename = "\(videoID).jpg"
            let keyedPath = thumbnailsDir.appendingPathComponent(keyedFilename).path

            if downloads[index].thumbnailPath == keyedFilename {
                if FileManager.default.fileExists(atPath: keyedPath) {
                    #if DEBUG
                    print("✅ [DownloadManager] Thumbnail found for: \(download.name)")
                    #endif
                    continue
                }
                // Keyed record but file missing — refetch below.
            } else if FileManager.default.fileExists(atPath: keyedPath) {
                // Keyed file already on disk (duplicate of the same video, or
                // a heal that landed before its record saved) — adopt it.
                downloads[index].thumbnailPath = keyedFilename
                downloads[index].thumbnailFetchFailedAtMs = nil
                needsSave = true
                continue
            }

            if shouldRetryThumbnail(download) {
                let downloadID = download.id
                EmbeddedPython.shared.ensureThumbnail(videoID: videoID) { [weak self] found in
                    if found {
                        self?.adoptKeyedThumbnail(downloadID: downloadID, filename: keyedFilename)
                    } else {
                        self?.recordThumbnailFetchFailed(downloadID: downloadID)
                    }
                }
            }
        }

        if needsSave {
            saveDownloads()
        }

        // Purge orphaned thumbnails (thumbnails with no matching audio file)
        purgeOrphanedThumbnails()

        #if DEBUG
        print("✅ [DownloadManager] Thumbnail validation complete")
        #endif
    }
    
    private func purgeOrphanedThumbnails() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let thumbnailsDir = documentsPath.appendingPathComponent("Thumbnails")
        
        guard let thumbnailFiles = try? FileManager.default.contentsOfDirectory(
            at: thumbnailsDir,
            includingPropertiesForKeys: nil
        ) else { return }
        
        // Build set of all thumbnail filenames that belong to a known download
        var knownThumbnailFilenames = Set(
            downloads.compactMap { $0.thumbnailPath }
                     .map { ($0 as NSString).lastPathComponent }
        )
        // Protect both key generations for live downloads: the legacy
        // audio-filename key (lock-screen artwork still resolves through it)
        // and the videoID key (a heal may land before its record saves).
        for download in downloads {
            knownThumbnailFilenames.insert("\(download.url.lastPathComponent).jpg")
            if let videoID = download.videoID, !videoID.isEmpty {
                knownThumbnailFilenames.insert("\(videoID).jpg")
            }
        }
        
        var deletedCount = 0
        for thumbnailFile in thumbnailFiles {
            let filename = thumbnailFile.lastPathComponent
            if !knownThumbnailFilenames.contains(filename) {
                do {
                    try FileManager.default.removeItem(at: thumbnailFile)
                    deletedCount += 1
                    print("🗑️ [DownloadManager] Purged orphaned thumbnail: \(filename)")
                } catch {
                    print("❌ [DownloadManager] Failed to purge thumbnail \(filename): \(error)")
                }
            }
        }
        
        if deletedCount > 0 {
            print("✅ [DownloadManager] Purged \(deletedCount) orphaned thumbnail(s)")
        } else {
            print("✅ [DownloadManager] No orphaned thumbnails found")
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