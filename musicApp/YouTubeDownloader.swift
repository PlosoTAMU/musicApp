import Foundation
import XCDYouTubeKit

class YouTubeDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    
    func downloadAudio(from youtubeURL: String, completion: @escaping (Track?) -> Void) {
        guard let videoID = extractVideoID(from: youtubeURL) else {
            errorMessage = "Invalid YouTube URL"
            completion(nil)
            return
        }
        
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        
        XCDYouTubeClient.default().getVideoWithIdentifier(videoID) { [weak self] video, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to get video info: \(error.localizedDescription)"
                    self.isDownloading = false
                    completion(nil)
                }
                return
            }
            
            guard let video = video else {
                DispatchQueue.main.async {
                    self.errorMessage = "Video not found"
                    self.isDownloading = false
                    completion(nil)
                }
                return
            }
            
            // Get the best audio stream
            let streamURLs = video.streamURLs
            var audioURL: URL?
            
            // Prefer audio-only streams (quality 140 is typically high-quality audio)
            if let url = streamURLs[XCDYouTubeVideoQuality.medium360.rawValue] ?? streamURLs[XCDYouTubeVideoQuality.small240.rawValue] {
                audioURL = url
            } else if let firstURL = streamURLs.values.first {
                audioURL = firstURL
            }
            
            guard let streamURL = audioURL else {
                DispatchQueue.main.async {
                    self.errorMessage = "No audio stream found"
                    self.isDownloading = false
                    completion(nil)
                }
                return
            }
            
            // Download the audio file
            self.downloadFile(from: streamURL, title: video.title) { track in
                DispatchQueue.main.async {
                    self.isDownloading = false
                    completion(track)
                }
            }
        }
    }
    
    private func downloadFile(from url: URL, title: String, completion: @escaping (Track?) -> Void) {
        let session = URLSession.shared
        let downloadTask = session.downloadTask(with: url) { [weak self] localURL, response, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                }
                completion(nil)
                return
            }
            
            guard let localURL = localURL else {
                DispatchQueue.main.async {
                    self.errorMessage = "No file downloaded"
                }
                completion(nil)
                return
            }
            
            // Create a permanent location in Documents
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let youtubeFolder = documentsPath.appendingPathComponent("YouTube Downloads", isDirectory: true)
            
            // Create folder if it doesn't exist
            try? FileManager.default.createDirectory(at: youtubeFolder, withIntermediateDirectories: true)
            
            // Clean filename
            let cleanTitle = title.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
            let destinationURL = youtubeFolder.appendingPathComponent("\(cleanTitle).m4a")
            
            // Remove if file already exists
            try? FileManager.default.removeItem(at: destinationURL)
            
            // Move downloaded file to permanent location
            do {
                try FileManager.default.moveItem(at: localURL, to: destinationURL)
                
                // Create track
                let track = Track(name: title, url: destinationURL, folderName: "YouTube Downloads")
                completion(track)
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to save file: \(error.localizedDescription)"
                }
                completion(nil)
            }
        }
        
        downloadTask.resume()
    }
    
    private func extractVideoID(from urlString: String) -> String? {
        // Handle various YouTube URL formats
        let patterns = [
            "(?<=v=)[^&#]+",           // youtube.com/watch?v=VIDEO_ID
            "(?<=be/)[^&#]+",          // youtu.be/VIDEO_ID
            "(?<=embed/)[^&#]+",       // youtube.com/embed/VIDEO_ID
            "(?<=v/)[^&#]+",           // youtube.com/v/VIDEO_ID
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range, in: urlString) {
                return String(urlString[range])
            }
        }
        
        return nil
    }
}