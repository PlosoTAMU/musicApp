import Foundation

class YouTubeDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    
    private let shellManager = ShellManager.shared
    
    func downloadAudio(from youtubeURL: String, completion: @escaping (Track?) -> Void) {
        guard shellManager.isReady else {
            DispatchQueue.main.async {
                self.errorMessage = "Python environment not ready. Please wait..."
            }
            completion(nil)
            return
        }
        
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        
        // Use ShellManager to extract video info with yt-dlp
        shellManager.executeYTDLP(url: youtubeURL) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let videoInfo):
                self.downloadFile(from: videoInfo.audioURL, title: videoInfo.title, completion: completion)
                
            case .failure(let error):
                DispatchQueue.main.async {
                    if let shellError = error as? ShellError {
                        switch shellError {
                        case .notInitialized:
                            self.errorMessage = "Python not initialized"
                        case .invalidURL:
                            self.errorMessage = "Invalid YouTube URL"
                        case .executionFailed:
                            self.errorMessage = "Failed to extract video info"
                        }
                    } else {
                        self.errorMessage = "Error: \(error.localizedDescription)"
                    }
                    self.isDownloading = false
                    completion(nil)
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
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            guard let localURL = localURL else {
                DispatchQueue.main.async {
                    self.errorMessage = "No file downloaded"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let youtubeFolder = documentsPath.appendingPathComponent("YouTube Downloads", isDirectory: true)
            
            try? FileManager.default.createDirectory(at: youtubeFolder, withIntermediateDirectories: true)
            
            let cleanTitle = title.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
            let destinationURL = youtubeFolder.appendingPathComponent("\(cleanTitle).m4a")
            
            try? FileManager.default.removeItem(at: destinationURL)
            
            do {
                try FileManager.default.moveItem(at: localURL, to: destinationURL)
                let track = Track(name: title, url: destinationURL, folderName: "YouTube Downloads")
                
                DispatchQueue.main.async {
                    self.isDownloading = false
                    completion(track)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to save: \(error.localizedDescription)"
                    self.isDownloading = false
                }
                completion(nil)
            }
        }
        
        downloadTask.resume()
    }
}