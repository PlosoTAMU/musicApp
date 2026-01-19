import Foundation

class YouTubeExtractor {
    
    static func extractVideoInfo(from url: String, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        guard let videoID = extractVideoID(from: url) else {
            completion(.failure(YouTubeError.invalidURL))
            return
        }
        
        // Use YouTube's internal API (used by the iOS app itself)
        let apiURL = URL(string: "https://www.youtube.com/youtubei/v1/player?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8")!
        
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.ios.youtube/19.09.3 (iPhone14,3; U; CPU iOS 17_5_1 like Mac OS X;)", forHTTPHeaderField: "User-Agent")
        
        let requestBody: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "19.09.3",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "videoId": videoID
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(YouTubeError.noData))
                return
            }
            
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                
                guard let videoDetails = json?["videoDetails"] as? [String: Any],
                      let streamingData = json?["streamingData"] as? [String: Any] else {
                    completion(.failure(YouTubeError.parsingFailed))
                    return
                }
                
                let title = videoDetails["title"] as? String ?? "Unknown"
                let author = videoDetails["author"] as? String ?? "Unknown"
                let lengthSeconds = (videoDetails["lengthSeconds"] as? String).flatMap { Int($0) } ?? 0
                
                // Get adaptive formats (separate audio/video streams)
                let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] ?? []
                
                // Filter audio-only formats
                let audioFormats = adaptiveFormats.filter { format in
                    let mimeType = format["mimeType"] as? String ?? ""
                    return mimeType.contains("audio")
                }
                
                // Sort by bitrate (quality)
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
                    duration: lengthSeconds,
                    audioURL: audioURL
                )
                
                completion(.success(videoInfo))
                
            } catch {
                completion(.failure(error))
            }
        }.resume()
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