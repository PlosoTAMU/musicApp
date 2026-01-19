import Foundation

class YouTubeExtractor {
    
    static func extractVideoInfo(from url: String, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        guard let videoID = extractVideoID(from: url) else {
            completion(.failure(YouTubeError.invalidURL))
            return
        }
        
        // First, try to get the video page HTML
        let videoPageURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        
        var request = URLRequest(url: videoPageURL)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data,
                  let html = String(data: data, encoding: .utf8) else {
                completion(.failure(YouTubeError.noData))
                return
            }
            
            // Extract title
            let title = extractTitle(from: html) ?? "YouTube Video"
            let author = extractAuthor(from: html) ?? "Unknown"
            
            // Try to extract player response JSON
            if let playerResponse = extractPlayerResponse(from: html) {
                do {
                    let json = try JSONSerialization.jsonObject(with: playerResponse.data(using: .utf8)!) as? [String: Any]
                    
                    guard let streamingData = json?["streamingData"] as? [String: Any] else {
                        completion(.failure(YouTubeError.noAudioStream))
                        return
                    }
                    
                    let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] ?? []
                    
                    // Find audio-only formats
                    let audioFormats = adaptiveFormats.filter { format in
                        let mimeType = format["mimeType"] as? String ?? ""
                        return mimeType.contains("audio")
                    }
                    
                    // Sort by bitrate
                    let sortedAudio = audioFormats.sorted { format1, format2 in
                        let bitrate1 = format1["bitrate"] as? Int ?? 0
                        let bitrate2 = format2["bitrate"] as? Int ?? 0
                        return bitrate1 > bitrate2
                    }
                    
                    guard let bestAudio = sortedAudio.first,
                          let urlString = bestAudio["url"] as? String,
                          let audioURL = URL(string: urlString) else {
                        completion(.failure(YouTubeError.noAudioStream))
                        return
                    }
                    
                    let videoInfo = VideoInfo(
                        title: title,
                        author: author,
                        duration: 0,
                        audioURL: audioURL
                    )
                    
                    completion(.success(videoInfo))
                    
                } catch {
                    completion(.failure(YouTubeError.parsingFailed))
                }
            } else {
                completion(.failure(YouTubeError.parsingFailed))
            }
        }.resume()
    }
    
    private static func extractPlayerResponse(from html: String) -> String? {
        // Look for ytInitialPlayerResponse in the HTML
        let patterns = [
            #"var ytInitialPlayerResponse = (\{.+?\});(?:var|</script>)"#,
            #"ytInitialPlayerResponse\s*=\s*(\{.+?\});"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range])
            }
        }
        
        return nil
    }
    
    private static func extractTitle(from html: String) -> String? {
        let patterns = [
            #"<title>(.+?) - YouTube</title>"#,
            #"\"title\":\"(.+?)\""#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let title = String(html[range])
                // Decode HTML entities
                return title.replacingOccurrences(of: "\\u0026", with: "&")
                    .replacingOccurrences(of: "\\/", with: "/")
            }
        }
        
        return nil
    }
    
    private static func extractAuthor(from html: String) -> String? {
        let pattern = #"\"author\":\"(.+?)\""#
        
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }
        
        return nil
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