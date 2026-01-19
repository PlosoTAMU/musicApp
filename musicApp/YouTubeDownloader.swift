import Foundation
import WebKit

class YouTubeDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    @Published var statusMessage: String = ""
    
    private let embeddedPython = EmbeddedPython.shared
    
    /// Download method priority:
    /// 1. Embedded Python + yt-dlp (if available)
    /// 2. WebView-based extraction (fallback)
    func downloadAudio(from youtubeURL: String, completion: @escaping (Track?) -> Void) {
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        statusMessage = "Starting download..."
        
        Task {
            do {
                let (fileURL, title): (URL, String)
                
                // Try embedded Python first (most reliable when available)
                if embeddedPython.isInitialized {
                    print("� [YouTubeDownloader] Using embedded Python + yt-dlp...")
                    updateStatus("Using yt-dlp...")
                    (fileURL, title) = try await embeddedPython.downloadAudio(url: youtubeURL)
                } else {
                    // Fallback to WebView method
                    print("🌐 [YouTubeDownloader] Using WebView method...")
                    updateStatus("Extracting via WebView...")
                    (fileURL, title) = try await YouTubeExtractor.shared.downloadAudioDirectly(from: youtubeURL)
                }
                
                let track = Track(name: title, url: fileURL, folderName: "YouTube Downloads")
                
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.downloadProgress = 1.0
                    self.statusMessage = "Download complete!"
                    completion(track)
                }
            } catch {
                print("❌ [YouTubeDownloader] Error: \(error.localizedDescription)")
                
                // If Python failed, try WebView as fallback
                if embeddedPython.isInitialized {
                    print("🔄 [YouTubeDownloader] Python failed, trying WebView fallback...")
                    updateStatus("Trying alternate method...")
                    
                    do {
                        let (fileURL, title) = try await YouTubeExtractor.shared.downloadAudioDirectly(from: youtubeURL)
                        let track = Track(name: title, url: fileURL, folderName: "YouTube Downloads")
                        
                        DispatchQueue.main.async {
                            self.isDownloading = false
                            self.downloadProgress = 1.0
                            self.statusMessage = "Download complete!"
                            completion(track)
                        }
                        return
                    } catch let fallbackError {
                        DispatchQueue.main.async {
                            self.errorMessage = "All methods failed: \(fallbackError.localizedDescription)"
                            self.isDownloading = false
                            self.statusMessage = "Download failed"
                            completion(nil)
                        }
                        return
                    }
                }
                
                DispatchQueue.main.async {
                    self.errorMessage = "Error: \(error.localizedDescription)"
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