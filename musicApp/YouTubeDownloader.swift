import Foundation

class YouTubeDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    
    func downloadAudio(from youtubeURL: String, completion: @escaping (Track?) -> Void) {
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        
        // Use native YouTubeExtractor instead of Python
        YouTubeExtractor.extractVideoInfo(from: youtubeURL) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let videoInfo):
                self.downloadFile(from: videoInfo.audioURL, title: videoInfo.title, clientType: videoInfo.clientType, completion: completion)
                
            case .failure(let error):
                DispatchQueue.main.async {
                    self.errorMessage = "Error: \(error.localizedDescription)"
                    self.isDownloading = false
                    completion(nil)
                }
            }
        }
    }
    
    private func downloadFile(from url: URL, title: String, clientType: YouTubeClientType, completion: @escaping (Track?) -> Void) {
        print("📥 [YouTubeDownloader] Starting download with \(clientType) client headers...")
        
        // Create request with headers matching the extraction client
        var request = URLRequest(url: url)
        request.setValue(clientType.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120 // 2 minutes for large files
        
        // Add cookies if available
        if let cookies = HTTPCookieStorage.shared.cookies {
            let youtubeCookies = cookies.filter { $0.domain.contains("youtube.com") || $0.domain.contains(".google.com") }
            if !youtubeCookies.isEmpty {
                let cookieString = youtubeCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                request.setValue(cookieString, forHTTPHeaderField: "Cookie")
                print("🍪 [YouTubeDownloader] Applied cookies to download request")
            }
        }
        
        // Use a custom session with no caching to avoid stale data issues
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let session = URLSession(configuration: config)
        let downloadTask = session.downloadTask(with: request) { [weak self] localURL, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ [YouTubeDownloader] Download error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 [YouTubeDownloader] Response status: \(httpResponse.statusCode)")
                if httpResponse.statusCode != 200 {
                    DispatchQueue.main.async {
                        self.errorMessage = "Download failed: HTTP \(httpResponse.statusCode)"
                        self.isDownloading = false
                    }
                    completion(nil)
                    return
                }
            }
            
            guard let localURL = localURL else {
                print("❌ [YouTubeDownloader] No local URL returned")
                DispatchQueue.main.async {
                    self.errorMessage = "No file downloaded"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            print("✅ [YouTubeDownloader] File downloaded to temp: \(localURL.path)")
            
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let youtubeFolder = documentsPath.appendingPathComponent("YouTube Downloads", isDirectory: true)
            
            try? FileManager.default.createDirectory(at: youtubeFolder, withIntermediateDirectories: true)
            
            let cleanTitle = title.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
            let destinationURL = youtubeFolder.appendingPathComponent("\(cleanTitle).m4a")
            
            try? FileManager.default.removeItem(at: destinationURL)
            
            do {
                try FileManager.default.moveItem(at: localURL, to: destinationURL)
                print("✅ [YouTubeDownloader] Saved to: \(destinationURL.lastPathComponent)")
                let track = Track(name: title, url: destinationURL, folderName: "YouTube Downloads")
                
                DispatchQueue.main.async {
                    self.isDownloading = false
                    completion(track)
                }
            } catch {
                print("❌ [YouTubeDownloader] Save error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to save: \(error.localizedDescription)"
                    self.isDownloading = false
                }
                completion(nil)
            }
        }
        
        downloadTask.resume()
        print("🚀 [YouTubeDownloader] Download task started")
    }
}