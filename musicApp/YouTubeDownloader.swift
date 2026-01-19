import Foundation

class YouTubeDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    @Published var statusMessage: String = ""
    
    private let embeddedPython = EmbeddedPython.shared
    
    func downloadAudio(from youtubeURL: String, completion: @escaping (Track?) -> Void) {
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        statusMessage = "Starting download..."
        
        guard embeddedPython.isInitialized else {
            DispatchQueue.main.async {
                self.errorMessage = "Python not initialized. Please set up yt-dlp first."
                self.isDownloading = false
                self.statusMessage = "Setup required"
                completion(nil)
            }
            return
        }
        
        Task {
            do {
                print("[YouTubeDownloader] Using yt-dlp...")
                updateStatus("Downloading with yt-dlp...")
                
                let (fileURL, title) = try await embeddedPython.downloadAudio(url: youtubeURL)
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
