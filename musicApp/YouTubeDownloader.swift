import Foundation

class YouTubeDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    @Published var statusMessage: String = ""
    
    func downloadAudio(from youtubeURL: String, completion: @escaping (Track?) -> Void) {
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        statusMessage = "Starting download..."
        
        Task {
            do {
                print("[YouTubeDownloader] Using yt-dlp...")
                updateStatus("Downloading with yt-dlp...")
                
                // Access the shared instance directly in the async context
                let python = await MainActor.run { PythonBridge.shared }
                let (fileURL, title) = try await python.downloadAudio(url: youtubeURL)
                let track = Track(name: title, url: fileURL, folderName: "YouTube Downloads")
                
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.downloadProgress = 1.0
                    self.statusMessage = "Download complete!"
                    completion(track)
                }
            } catch {
                print("[YouTubeDownloader] Error: \(error.localizedDescription)")
                
                DispatchQueue.main.async {
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    self.isDownloading = false
                    self.statusMessage = "Download failed"
                    completion(nil)
                }
            }
        }
    }
    
    private func updateStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
        }
    }
}

// Bridge to access EmbeddedPython
@MainActor
class PythonBridge {
    static let shared = PythonBridge()
    private let python = EmbeddedPython.shared
    
    func downloadAudio(url: String) async throws -> (URL, String) {
        return try await python.downloadAudio(url: url)
    }
    
    func getThumbnailPath(for fileURL: URL) -> URL? {
        return python.getThumbnailPath(for: fileURL)
    }
}