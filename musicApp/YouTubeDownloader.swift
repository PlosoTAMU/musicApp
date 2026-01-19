import Foundation
import WebKit

class YouTubeDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    
    func downloadAudio(from youtubeURL: String, completion: @escaping (Track?) -> Void) {
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        
        // Use the extractor's direct download method
        Task {
            do {
                let (fileURL, title) = try await YouTubeExtractor.shared.downloadAudioDirectly(from: youtubeURL)
                
                let track = Track(name: title, url: fileURL, folderName: "YouTube Downloads")
                
                DispatchQueue.main.async {
                    self.isDownloading = false
                    completion(track)
                }
            } catch {
                print("❌ [YouTubeDownloader] Error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.errorMessage = "Error: \(error.localizedDescription)"
                    self.isDownloading = false
                    completion(nil)
                }
            }
        }
    }
}