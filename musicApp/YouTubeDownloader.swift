import Foundation
import YouTubeKit

class YouTubeDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    
    private let youtube = YouTube()
    
    func downloadAudio(from youtubeURL: String, completion: @escaping (Track?) -> Void) {
        guard let videoID = extractVideoID(from: youtubeURL) else {
            errorMessage = "Invalid YouTube URL"
            completion(nil)
            return
        }
        
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        
        Task {
            do {
                let video = try await youtube.video(id: videoID)
                
                // Get audio stream
                guard let audioStream = video.streamingData?.adaptiveFormats.first(where: { 
                    $0.mimeType.contains("audio")
                }) else {
                    await MainActor.run {
                        self.errorMessage = "No audio stream found"
                        self.isDownloading = false
                    }
                    completion(nil)
                    return
                }
                
                guard let streamURL = audioStream.url else {
                    await MainActor.run {
                        self.errorMessage = "Could not get stream URL"
                        self.isDownloading = false
                    }
                    completion(nil)
                    return
                }
                
                await self.downloadFile(from: streamURL, title: video.title) { track in
                    Task { @MainActor in
                        self.isDownloading = false
                        completion(track)
                    }
                }
                
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed: \(error.localizedDescription)"
                    self.isDownloading = false
                }
                completion(nil)
            }
        }
    }
    
    private func downloadFile(from url: URL, title: String, completion: @escaping (Track?) -> Void) async {
        let session = URLSession.shared
        
        do {
            let (localURL, _) = try await session.download(from: url)
            
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let youtubeFolder = documentsPath.appendingPathComponent("YouTube Downloads", isDirectory: true)
            
            try? FileManager.default.createDirectory(at: youtubeFolder, withIntermediateDirectories: true)
            
            let cleanTitle = title.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
            let destinationURL = youtubeFolder.appendingPathComponent("\(cleanTitle).m4a")
            
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: localURL, to: destinationURL)
            
            let track = Track(name: title, url: destinationURL, folderName: "YouTube Downloads")
            completion(track)
            
        } catch {
            await MainActor.run {
                self.errorMessage = "Download failed: \(error.localizedDescription)"
            }
            completion(nil)
        }
    }
    
    private func extractVideoID(from urlString: String) -> String? {
        let patterns = [
            "(?<=v=)[^&#]+",
            "(?<=be/)[^&#]+",
            "(?<=embed/)[^&#]+",
            "(?<=v/)[^&#]+",
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