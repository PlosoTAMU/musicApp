import Foundation

class YouTubeExtractor {
    
    static func extractVideoInfo(from url: String, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        print("🔍 [YouTubeExtractor] Starting extraction via Shell")
        
        ShellManager.shared.executeYTDLP(url: url, completion: completion)
    }
}