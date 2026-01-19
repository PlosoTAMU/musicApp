import Foundation
import WebKit

class YouTubeDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    
    private var downloadCompletion: ((Track?) -> Void)?
    private var currentTitle: String = ""
    private var downloadSession: URLSession?
    
    override init() {
        super.init()
    }
    
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
        print("📥 [YouTubeDownloader] Starting download...")
        print("📥 [YouTubeDownloader] URL: \(url.absoluteString.prefix(200))...")
        
        self.downloadCompletion = completion
        self.currentTitle = title
        
        // Try downloading with WKWebView-based session first (uses authenticated cookies)
        downloadViaWebViewSession(url: url, title: title, clientType: clientType, completion: completion)
    }
    
    private func downloadViaWebViewSession(url: URL, title: String, clientType: YouTubeClientType, completion: @escaping (Track?) -> Void) {
        // Get cookies from WKWebsiteDataStore and create a proper session
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            
            let youtubeCookies = cookies.filter { $0.domain.contains("youtube") || $0.domain.contains("google") }
            print("🍪 [YouTubeDownloader] Got \(youtubeCookies.count) cookies from WKWebView")
            
            // Create request
            var request = URLRequest(url: url)
            request.setValue(clientType.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 300
            
            // Create cookie string from WKWebView cookies
            if !youtubeCookies.isEmpty {
                let cookieString = youtubeCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                request.setValue(cookieString, forHTTPHeaderField: "Cookie")
                print("🍪 [YouTubeDownloader] Applied \(cookieString.count) chars of cookies")
            }
            
            // Use ephemeral session with our cookies
            let config = URLSessionConfiguration.ephemeral
            config.httpAdditionalHeaders = [
                "User-Agent": clientType.userAgent,
                "Origin": "https://www.youtube.com",
                "Referer": "https://www.youtube.com/"
            ]
            
            // Add cookies to session
            for cookie in youtubeCookies {
                config.httpCookieStorage?.setCookie(cookie)
            }
            
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.downloadSession = session
            
            let downloadTask = session.downloadTask(with: request)
            downloadTask.resume()
            print("🚀 [YouTubeDownloader] Download task started with delegate")
        }
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        print("✅ [YouTubeDownloader] Download finished to: \(location.path)")
        
        // Check HTTP response first
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            print("📡 [YouTubeDownloader] HTTP Status: \(httpResponse.statusCode)")
            print("📡 [YouTubeDownloader] Content-Type: \(httpResponse.mimeType ?? "unknown")")
            
            if httpResponse.statusCode == 403 {
                print("❌ [YouTubeDownloader] Got 403 - access denied")
                DispatchQueue.main.async {
                    self.errorMessage = "Access denied (403)"
                    self.isDownloading = false
                    self.downloadCompletion?(nil)
                }
                return
            }
            
            // Check if we got HTML instead of audio (error page)
            if let mimeType = httpResponse.mimeType, mimeType.contains("text/html") {
                print("❌ [YouTubeDownloader] Got HTML instead of audio - likely error page")
                // Try to read what we got
                if let content = try? String(contentsOf: location, encoding: .utf8) {
                    print("📄 [YouTubeDownloader] Content preview: \(content.prefix(500))")
                }
                DispatchQueue.main.async {
                    self.errorMessage = "Got error page instead of audio"
                    self.isDownloading = false
                    self.downloadCompletion?(nil)
                }
                return
            }
        }
        
        // Check file size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: location.path),
           let fileSize = attributes[.size] as? Int64 {
            print("📦 [YouTubeDownloader] File size: \(fileSize) bytes (\(fileSize / 1024) KB)")
            
            if fileSize < 10000 { // Less than 10KB is suspicious
                print("⚠️ [YouTubeDownloader] File too small, might be error page")
                if let content = try? String(contentsOf: location, encoding: .utf8) {
                    print("📄 [YouTubeDownloader] Content: \(content.prefix(1000))")
                }
                DispatchQueue.main.async {
                    self.errorMessage = "Downloaded file too small - likely an error"
                    self.isDownloading = false
                    self.downloadCompletion?(nil)
                }
                return
            }
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let youtubeFolder = documentsPath.appendingPathComponent("YouTube Downloads", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: youtubeFolder, withIntermediateDirectories: true)
        
        let cleanTitle = currentTitle.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let destinationURL = youtubeFolder.appendingPathComponent("\(cleanTitle).m4a")
        
        try? FileManager.default.removeItem(at: destinationURL)
        
        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
            print("✅ [YouTubeDownloader] Saved to: \(destinationURL.lastPathComponent)")
            let track = Track(name: currentTitle, url: destinationURL, folderName: "YouTube Downloads")
            
            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadCompletion?(track)
            }
        } catch {
            print("❌ [YouTubeDownloader] Save error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.errorMessage = "Failed to save: \(error.localizedDescription)"
                self.isDownloading = false
                self.downloadCompletion?(nil)
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async {
                self.downloadProgress = progress
            }
            print("📊 [YouTubeDownloader] Progress: \(Int(progress * 100))%")
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("❌ [YouTubeDownloader] Task error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.errorMessage = "Download failed: \(error.localizedDescription)"
                self.isDownloading = false
                self.downloadCompletion?(nil)
            }
        }
        
        if let httpResponse = task.response as? HTTPURLResponse {
            print("📡 [YouTubeDownloader] Final response: \(httpResponse.statusCode)")
            if httpResponse.statusCode == 403 {
                DispatchQueue.main.async {
                    self.errorMessage = "Access denied (403). Try signing out and back in."
                    self.isDownloading = false
                    self.downloadCompletion?(nil)
                }
            }
        }
    }
}