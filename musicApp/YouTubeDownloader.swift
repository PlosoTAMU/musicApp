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
        
        Task { @MainActor in
            do {
                print("[YouTubeDownloader] Using yt-dlp...")
                self.statusMessage = "Downloading with yt-dlp..."
                
                // Direct access with MainActor
                let (fileURL, title) = try await EmbeddedPython.shared.downloadAudio(url: youtubeURL)
                let track = Track(name: title, url: fileURL, folderName: "YouTube Downloads")
                
                self.isDownloading = false
                self.downloadProgress = 1.0
                self.statusMessage = "Download complete!"
                completion(track)
            } catch {
                print("[YouTubeDownloader] Error: \(error.localizedDescription)")
                
                self.errorMessage = "Download failed: \(error.localizedDescription)"
                self.isDownloading = false
                self.statusMessage = "Download failed"
                completion(nil)
            }
        }
    }
    
    private func updateStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
        }
    }
}