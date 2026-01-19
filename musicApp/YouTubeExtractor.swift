import Foundation
import PythonKit

class YouTubeExtractor {
    
    static func extractVideoInfo(from url: String, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        print("🔍 [YouTubeExtractor] Starting extraction for URL: \(url)")
        
        guard let videoID = extractVideoID(from: url) else {
            print("❌ [YouTubeExtractor] Failed to extract video ID")
            completion(.failure(YouTubeError.invalidURL))
            return
        }
        
        print("✅ [YouTubeExtractor] Video ID: \(videoID)")
        
        // Run on background thread since this can be slow
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print("📡 [YouTubeExtractor] Initializing yt-dlp...")
                
                // Import yt-dlp Python module
                let yt_dlp = Python.import("yt_dlp")
                
                print("✅ [YouTubeExtractor] yt-dlp imported")
                
                // Configure options
                let opts: [String: PythonObject] = [
                    "format": "bestaudio/best",
                    "quiet": true,
                    "no_warnings": true,
                    "extract_flat": false
                ]
                
                print("🔎 [YouTubeExtractor] Extracting video info...")
                
                // Create YoutubeDL instance and extract info
                let ydl = yt_dlp.YoutubeDL(opts)
                let info = try ydl.extract_info(url, download: false)
                
                print("✅ [YouTubeExtractor] Info extracted")
                
                // Get video details
                let title = String(info["title"]) ?? "YouTube Video"
                let author = String(info["uploader"]) ?? "Unknown"
                let duration = Int(info["duration"]) ?? 0
                
                print("📝 [YouTubeExtractor] Title: \(title)")
                print("👤 [YouTubeExtractor] Author: \(author)")
                
                // Get best audio URL
                guard let urlString = String(info["url"]) else {
                    print("❌ [YouTubeExtractor] No URL in response")
                    DispatchQueue.main.async {
                        completion(.failure(YouTubeError.noAudioStream))
                    }
                    return
                }
                
                guard let audioURL = URL(string: urlString) else {
                    print("❌ [YouTubeExtractor] Invalid URL format")
                    DispatchQueue.main.async {
                        completion(.failure(YouTubeError.noAudioStream))
                    }
                    return
                }
                
                print("🎯 [YouTubeExtractor] Audio URL obtained")
                
                let videoInfo = VideoInfo(
                    title: title,
                    author: author,
                    duration: duration,
                    audioURL: audioURL
                )
                
                print("🎉 [YouTubeExtractor] Success!")
                
                DispatchQueue.main.async {
                    completion(.success(videoInfo))
                }
                
            } catch {
                print("❌ [YouTubeExtractor] Error: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    private static func extractVideoID(from urlString: String) -> String? {
        let patterns = [
            #"(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/embed\/)([^&#?]+)"#,
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range(at: 1), in: urlString) {
                return String(urlString[range])
            }
        }
        
        return nil
    }
}

struct VideoInfo {
    let title: String
    let author: String
    let duration: Int
    let audioURL: URL
}

enum YouTubeError: Error {
    case invalidURL
    case noData
    case parsingFailed
    case noAudioStream
}