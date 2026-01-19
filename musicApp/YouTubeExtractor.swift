import Foundation

/// Native Swift YouTube audio extractor - no Python required
class YouTubeExtractor {
    static let shared = YouTubeExtractor()
    
    enum ExtractionError: Error, LocalizedError {
        case invalidURL
        case noVideoID
        case networkError(Error)
        case parsingError
        case noAudioStream
        case ageRestricted
        
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid YouTube URL"
            case .noVideoID: return "Could not extract video ID"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .parsingError: return "Could not parse video info"
            case .noAudioStream: return "No audio stream found"
            case .ageRestricted: return "Video is age restricted"
            }
        }
    }
    
    /// Extract video ID from various YouTube URL formats
    func extractVideoID(from urlString: String) -> String? {
        let patterns = [
            "(?:youtube\\.com/watch\\?v=|youtu\\.be/|youtube\\.com/embed/|youtube\\.com/v/)([a-zA-Z0-9_-]{11})",
            "^([a-zA-Z0-9_-]{11})$"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: urlString, options: [], range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range(at: 1), in: urlString) {
                return String(urlString[range])
            }
        }
        return nil
    }
    
    /// Extract audio info - tries multiple methods with fallbacks
    func extractInfo(from urlString: String) async throws -> VideoInfo {
        guard let videoID = extractVideoID(from: urlString) else {
            throw ExtractionError.noVideoID
        }
        
        print("🎬 [YouTubeExtractor] Extracting info for video ID: \(videoID)")
        
        // Try direct YouTube API first
        do {
            return try await extractViaYouTubeAPI(videoID: videoID)
        } catch {
            print("⚠️ [YouTubeExtractor] Direct API failed: \(error.localizedDescription)")
            print("🔄 [YouTubeExtractor] Trying Invidious fallback...")
        }
        
        // Fallback to Invidious instances
        return try await extractViaInvidious(videoID: videoID)
    }
    
    /// Direct YouTube API extraction
    private func extractViaYouTubeAPI(videoID: String) async throws -> VideoInfo {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "19.09.3",
                    "deviceModel": "iPhone14,3",
                    "userAgent": "com.google.ios.youtube/19.09.3 (iPhone14,3; U; CPU iOS 15_6 like Mac OS X)",
                    "hl": "en",
                    "gl": "US",
                    "utcOffsetMinutes": 0
                ]
            ],
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ExtractionError.networkError(NSError(domain: "HTTP", code: (response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractionError.parsingError
        }
        
        // Check for playability errors
        if let playabilityStatus = json["playabilityStatus"] as? [String: Any],
           let status = playabilityStatus["status"] as? String,
           status != "OK" {
            let reason = playabilityStatus["reason"] as? String ?? "Unknown error"
            print("❌ [YouTubeExtractor] Playability error: \(reason)")
            throw ExtractionError.parsingError
        }
        
        // Extract video details
        guard let videoDetails = json["videoDetails"] as? [String: Any] else {
            throw ExtractionError.parsingError
        }
        
        let title = videoDetails["title"] as? String ?? "Unknown"
        let author = videoDetails["author"] as? String ?? "Unknown"
        let durationStr = videoDetails["lengthSeconds"] as? String ?? "0"
        let duration = Int(durationStr) ?? 0
        
        // Extract streaming data
        guard let streamingData = json["streamingData"] as? [String: Any] else {
            throw ExtractionError.noAudioStream
        }
        
        // Look for adaptive formats (better quality audio)
        var audioURL: URL? = nil
        
        if let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] {
            let audioFormats = adaptiveFormats.filter { format in
                if let mimeType = format["mimeType"] as? String {
                    return mimeType.contains("audio")
                }
                return false
            }.sorted { a, b in
                let bitrateA = a["bitrate"] as? Int ?? 0
                let bitrateB = b["bitrate"] as? Int ?? 0
                return bitrateA > bitrateB
            }
            
            if let bestAudio = audioFormats.first {
                if let urlStr = bestAudio["url"] as? String {
                    audioURL = URL(string: urlStr)
                }
            }
        }
        
        // Fallback to regular formats
        if audioURL == nil, let formats = streamingData["formats"] as? [[String: Any]] {
            if let format = formats.first, let urlStr = format["url"] as? String {
                audioURL = URL(string: urlStr)
            }
        }
        
        guard let finalAudioURL = audioURL else {
            throw ExtractionError.noAudioStream
        }
        
        print("✅ [YouTubeExtractor] Found audio URL for: \(title)")
        
        return VideoInfo(
            title: title,
            author: author,
            duration: duration,
            audioURL: finalAudioURL
        )
    }
    
    /// Fallback extraction via Invidious public instances
    private func extractViaInvidious(videoID: String) async throws -> VideoInfo {
        // List of public Invidious instances (these may change over time)
        let instances = [
            "https://inv.nadeko.net",
            "https://invidious.nerdvpn.de",
            "https://invidious.jing.rocks",
            "https://yewtu.be",
            "https://invidious.protokolla.fi"
        ]
        
        var lastError: Error = ExtractionError.noAudioStream
        
        for instance in instances {
            do {
                print("🔄 [YouTubeExtractor] Trying Invidious: \(instance)")
                let info = try await extractFromInvidiousInstance(instance: instance, videoID: videoID)
                return info
            } catch {
                print("⚠️ [YouTubeExtractor] Instance \(instance) failed: \(error.localizedDescription)")
                lastError = error
                continue
            }
        }
        
        throw lastError
    }
    
    private func extractFromInvidiousInstance(instance: String, videoID: String) async throws -> VideoInfo {
        let urlString = "\(instance)/api/v1/videos/\(videoID)"
        guard let url = URL(string: urlString) else {
            throw ExtractionError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ExtractionError.networkError(NSError(domain: "HTTP", code: (response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractionError.parsingError
        }
        
        let title = json["title"] as? String ?? "Unknown"
        let author = json["author"] as? String ?? "Unknown"
        let duration = json["lengthSeconds"] as? Int ?? 0
        
        // Get audio streams from adaptiveFormats
        var audioURL: URL? = nil
        
        if let adaptiveFormats = json["adaptiveFormats"] as? [[String: Any]] {
            // Filter for audio-only formats and sort by bitrate
            let audioFormats = adaptiveFormats.filter { format in
                let type = format["type"] as? String ?? ""
                return type.contains("audio")
            }.sorted { a, b in
                let bitrateA = (a["bitrate"] as? String).flatMap { Int($0) } ?? a["bitrate"] as? Int ?? 0
                let bitrateB = (b["bitrate"] as? String).flatMap { Int($0) } ?? b["bitrate"] as? Int ?? 0
                return bitrateA > bitrateB
            }
            
            if let bestAudio = audioFormats.first, let urlStr = bestAudio["url"] as? String {
                audioURL = URL(string: urlStr)
            }
        }
        
        // Fallback to formatStreams
        if audioURL == nil, let formatStreams = json["formatStreams"] as? [[String: Any]] {
            if let format = formatStreams.first, let urlStr = format["url"] as? String {
                audioURL = URL(string: urlStr)
            }
        }
        
        guard let finalAudioURL = audioURL else {
            throw ExtractionError.noAudioStream
        }
        
        print("✅ [YouTubeExtractor] Found audio via Invidious for: \(title)")
        
        return VideoInfo(
            title: title,
            author: author,
            duration: duration,
            audioURL: finalAudioURL
        )
    }
    
    /// Completion handler version for backward compatibility
    static func extractVideoInfo(from url: String, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        print("🔍 [YouTubeExtractor] Starting native extraction")
        
        Task {
            do {
                let info = try await YouTubeExtractor.shared.extractInfo(from: url)
                DispatchQueue.main.async {
                    completion(.success(info))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// Download audio to a file
    func downloadAudio(from urlString: String, to destinationURL: URL) async throws -> URL {
        let info = try await extractInfo(from: urlString)
        
        print("📥 [YouTubeExtractor] Downloading: \(info.title)")
        
        let (tempURL, response) = try await URLSession.shared.download(from: info.audioURL)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ExtractionError.networkError(NSError(domain: "HTTP", code: (response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        
        // Move to destination
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
        
        print("✅ [YouTubeExtractor] Saved to: \(destinationURL.lastPathComponent)")
        
        return destinationURL
    }
}