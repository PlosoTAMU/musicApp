import Foundation

class YouTubeExtractor {
    
    static func extractVideoInfo(from url: String, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        print("🔍 [YouTubeExtractor] Starting extraction for URL: \(url)")
        
        guard let videoID = extractVideoID(from: url) else {
            print("❌ [YouTubeExtractor] Failed to extract video ID from URL")
            completion(.failure(YouTubeError.invalidURL))
            return
        }
        
        print("✅ [YouTubeExtractor] Extracted video ID: \(videoID)")
        
        // Use the embed page which often has simpler protections
        let embedURL = URL(string: "https://www.youtube.com/embed/\(videoID)")!
        
        var request = URLRequest(url: embedURL)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        
        print("📡 [YouTubeExtractor] Fetching embed page...")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ [YouTubeExtractor] Network error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📊 [YouTubeExtractor] HTTP Status: \(httpResponse.statusCode)")
            }
            
            guard let data = data else {
                print("❌ [YouTubeExtractor] No data received")
                completion(.failure(YouTubeError.noData))
                return
            }
            
            print("✅ [YouTubeExtractor] Received \(data.count) bytes")
            
            guard let html = String(data: data, encoding: .utf8) else {
                print("❌ [YouTubeExtractor] Failed to decode HTML as UTF-8")
                completion(.failure(YouTubeError.noData))
                return
            }
            
            print("✅ [YouTubeExtractor] HTML decoded, length: \(html.count) characters")
            
            // Extract title
            let title = extractTitle(from: html) ?? "YouTube Video"
            print("📝 [YouTubeExtractor] Title: \(title)")
            
            let author = extractAuthor(from: html) ?? "Unknown"
            print("👤 [YouTubeExtractor] Author: \(author)")
            
            // Try to extract player response JSON
            print("🔎 [YouTubeExtractor] Looking for ytInitialPlayerResponse...")
            
            if let playerResponse = extractPlayerResponse(from: html) {
                print("✅ [YouTubeExtractor] Found ytInitialPlayerResponse, length: \(playerResponse.count)")
                
                do {
                    guard let responseData = playerResponse.data(using: .utf8) else {
                        print("❌ [YouTubeExtractor] Failed to convert player response to data")
                        completion(.failure(YouTubeError.parsingFailed))
                        return
                    }
                    
                    let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
                    
                    print("✅ [YouTubeExtractor] Parsed player response JSON")
                    print("🔑 [YouTubeExtractor] Top-level keys: \(json?.keys.joined(separator: ", ") ?? "none")")
                    
                    // Check playability status first
                    if let playabilityStatus = json?["playabilityStatus"] as? [String: Any] {
                        let status = playabilityStatus["status"] as? String ?? "unknown"
                        print("📊 [YouTubeExtractor] Playability status: \(status)")
                        
                        if status != "OK" {
                            if let reason = playabilityStatus["reason"] as? String {
                                print("⚠️ [YouTubeExtractor] Reason: \(reason)")
                            }
                        }
                    }
                    
                    guard let streamingData = json?["streamingData"] as? [String: Any] else {
                        print("❌ [YouTubeExtractor] No 'streamingData' in response")
                        completion(.failure(YouTubeError.noAudioStream))
                        return
                    }
                    
                    print("✅ [YouTubeExtractor] Found streamingData")
                    print("🔑 [YouTubeExtractor] StreamingData keys: \(streamingData.keys.joined(separator: ", "))")
                    
                    let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] ?? []
                    let formats = streamingData["formats"] as? [[String: Any]] ?? []
                    let allFormats = adaptiveFormats + formats
                    
                    print("📊 [YouTubeExtractor] Found \(adaptiveFormats.count) adaptive formats + \(formats.count) regular formats")
                    
                    // Find audio-only or combined formats
                    let audioFormats = allFormats.filter { format in
                        let mimeType = format["mimeType"] as? String ?? ""
                        let hasAudioQuality = format["audioQuality"] != nil
                        let isAudioOnly = mimeType.contains("audio")
                        
                        if isAudioOnly || hasAudioQuality {
                            print("  🎵 Found format: \(mimeType), audioQuality: \(format["audioQuality"] ?? "none")")
                            print("     Has URL: \(format["url"] != nil), Has signatureCipher: \(format["signatureCipher"] != nil)")
                        }
                        
                        return isAudioOnly || hasAudioQuality
                    }
                    
                    print("✅ [YouTubeExtractor] Found \(audioFormats.count) audio-capable formats")
                    
                    if audioFormats.isEmpty {
                        print("❌ [YouTubeExtractor] No audio formats found")
                        print("📄 [YouTubeExtractor] All format MIME types:")
                        for format in allFormats {
                            print("   - \(format["mimeType"] ?? "unknown")")
                        }
                        completion(.failure(YouTubeError.noAudioStream))
                        return
                    }
                    
                    // Sort by audio bitrate
                    let sortedAudio = audioFormats.sorted { format1, format2 in
                        let bitrate1 = format1["bitrate"] as? Int ?? format1["averageBitrate"] as? Int ?? 0
                        let bitrate2 = format2["bitrate"] as? Int ?? format2["averageBitrate"] as? Int ?? 0
                        return bitrate1 > bitrate2
                    }
                    
                    guard let bestAudio = sortedAudio.first else {
                        print("❌ [YouTubeExtractor] Could not select best audio format")
                        completion(.failure(YouTubeError.noAudioStream))
                        return
                    }
                    
                    let bitrate = bestAudio["bitrate"] as? Int ?? bestAudio["averageBitrate"] as? Int ?? 0
                    print("🎯 [YouTubeExtractor] Selected format with bitrate: \(bitrate)")
                    print("🔑 [YouTubeExtractor] Format keys: \(bestAudio.keys.joined(separator: ", "))")
                    
                    // Check if we have a direct URL or need to decipher
                    var audioURLString: String?
                    
                    if let directURL = bestAudio["url"] as? String {
                        print("✅ [YouTubeExtractor] Found direct URL")
                        audioURLString = directURL
                    } else if let signatureCipher = bestAudio["signatureCipher"] as? String {
                        print("⚠️ [YouTubeExtractor] Format requires signature deciphering")
                        print("📝 [YouTubeExtractor] SignatureCipher: \(String(signatureCipher.prefix(200)))...")
                        
                        // Parse the cipher (format: s=SIGNATURE&url=URL)
                        if let parsedURL = parseSignatureCipher(signatureCipher) {
                            print("✅ [YouTubeExtractor] Parsed URL from cipher")
                            audioURLString = parsedURL
                        } else {
                            print("❌ [YouTubeExtractor] Failed to parse signature cipher")
                        }
                    } else {
                        print("❌ [YouTubeExtractor] No URL or signatureCipher found")
                    }
                    
                    guard let urlString = audioURLString,
                          let audioURL = URL(string: urlString) else {
                        print("❌ [YouTubeExtractor] Failed to create valid URL")
                        completion(.failure(YouTubeError.noAudioStream))
                        return
                    }
                    
                    print("✅ [YouTubeExtractor] Audio URL created successfully")
                    print("🔗 [YouTubeExtractor] URL host: \(audioURL.host ?? "none")")
                    
                    let videoInfo = VideoInfo(
                        title: title,
                        author: author,
                        duration: 0,
                        audioURL: audioURL
                    )
                    
                    print("🎉 [YouTubeExtractor] Successfully extracted video info!")
                    completion(.success(videoInfo))
                    
                } catch {
                    print("❌ [YouTubeExtractor] JSON parsing error: \(error.localizedDescription)")
                    completion(.failure(YouTubeError.parsingFailed))
                }
            } else {
                print("❌ [YouTubeExtractor] Could not find ytInitialPlayerResponse in HTML")
                print("📄 [YouTubeExtractor] Searching for alternate patterns...")
                
                
                
                completion(.failure(YouTubeError.parsingFailed))
            }
        }.resume()
    }
    
    private static func parseSignatureCipher(_ cipher: String) -> String? {
        // Parse URL-encoded parameters
        let components = cipher.components(separatedBy: "&")
        var params: [String: String] = [:]
        
        for component in components {
            let keyValue = component.components(separatedBy: "=")
            if keyValue.count == 2 {
                if let key = keyValue[0].removingPercentEncoding,
                   let value = keyValue[1].removingPercentEncoding {
                    params[key] = value
                }
            }
        }
        
        // For now, we'll try to use the URL without the signature
        // This may or may not work depending on YouTube's current requirements
        if let url = params["url"] {
            print("⚠️ [YouTubeExtractor] Attempting to use URL without signature verification")
            return url
        }
        
        return nil
    }
    
    
    
    private static func extractPlayerResponse(from html: String) -> String? {
        let patterns = [
            #"var ytInitialPlayerResponse = (\{.+?\});(?:var|</script>)"#,
            #"ytInitialPlayerResponse\s*=\s*(\{.+?\});"#,
            #"ytInitialPlayerResponse"\s*:\s*(\{.+?\}),"#
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
            #""title":"(.+?)""#,
            #"\"title\":\"(.+?)\""#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let title = String(html[range])
                return title.replacingOccurrences(of: "\\u0026", with: "&")
                    .replacingOccurrences(of: "\\/", with: "/")
                    .replacingOccurrences(of: "\\\"", with: "\"")
            }
        }
        
        return nil
    }
    
    private static func extractAuthor(from html: String) -> String? {
        let patterns = [
            #""author":"(.+?)""#,
            #"\"author\":\"(.+?)\""#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range])
            }
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