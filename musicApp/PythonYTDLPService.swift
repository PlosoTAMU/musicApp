import Foundation

/// Manages connection to a yt-dlp server for YouTube audio extraction
/// The server runs on your computer or a remote host - iOS connects to it
class PythonYTDLPService: ObservableObject {
    static let shared = PythonYTDLPService()
    
    @Published var isRunning = false
    @Published var statusMessage = ""
    @Published var downloadProgress: Double = 0.0
    @Published var serverAddress: String = ""
    
    private var baseURL: URL? {
        guard !serverAddress.isEmpty else { return nil }
        // Add http:// if not present
        let address = serverAddress.hasPrefix("http") ? serverAddress : "http://\(serverAddress)"
        return URL(string: address)
    }
    
    private let serverPort = 8765
    
    init() {
        // Load saved server address
        if let saved = UserDefaults.standard.string(forKey: "ytdlp_server_address") {
            serverAddress = saved
        }
    }
    
    /// Save server address
    func setServerAddress(_ address: String) {
        serverAddress = address
        UserDefaults.standard.set(address, forKey: "ytdlp_server_address")
    }
    
    /// Check if the server is running
    func checkHealth() async -> Bool {
        guard let baseURL = baseURL else {
            DispatchQueue.main.async {
                self.isRunning = false
                self.statusMessage = "No server address configured"
            }
            return false
        }
        
        let healthURL = baseURL.appendingPathComponent("health")
        
        do {
            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 5
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                DispatchQueue.main.async {
                    self.isRunning = false
                }
                return false
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String,
               status == "ok" {
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.statusMessage = "Connected to server"
                }
                return true
            }
        } catch {
            print("[PythonYTDLP] Health check failed: \(error)")
        }
        
        DispatchQueue.main.async {
            self.isRunning = false
            self.statusMessage = "Cannot connect to server"
        }
        return false
    }
    
    /// Get video info without downloading
    func getVideoInfo(url: String) async throws -> VideoInfo {
        guard let baseURL = baseURL else {
            throw YTDLPError.serverNotRunning
        }
        
        let infoURL = baseURL.appendingPathComponent("info")
        var components = URLComponents(url: infoURL, resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw YTDLPError.serverError("Failed to get video info")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTDLPError.parseError
        }
        
        if let error = json["error"] as? String {
            throw YTDLPError.serverError(error)
        }
        
        return VideoInfo(
            title: json["title"] as? String ?? "Unknown",
            author: json["author"] as? String ?? "Unknown",
            duration: json["duration"] as? Int ?? 0,
            audioURL: URL(string: "about:blank")!,  // Not used for this path
            clientType: .ios
        )
    }
    
    /// Download audio from YouTube URL
    func downloadAudio(url: String, outputDir: String? = nil) async throws -> (URL, String) {
        guard let baseURL = baseURL else {
            throw YTDLPError.serverNotRunning
        }
        
        DispatchQueue.main.async {
            self.statusMessage = "Connecting to server..."
            self.downloadProgress = 0.0
        }
        
        // Check if server is running
        guard await checkHealth() else {
            throw YTDLPError.serverNotRunning
        }
        
        DispatchQueue.main.async {
            self.statusMessage = "Downloading audio..."
            self.downloadProgress = 0.1
        }
        
        // Build download URL - server will download and we'll fetch the file
        let downloadURL = baseURL.appendingPathComponent("download")
        var components = URLComponents(url: downloadURL, resolvingAgainstBaseURL: true)!
        
        // Don't send outputDir - server will use temp and return file data
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        
        // Make request with longer timeout
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 300  // 5 minutes for download
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw YTDLPError.serverError("Download request failed")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTDLPError.parseError
        }
        
        if let error = json["error"] as? String {
            throw YTDLPError.serverError(error)
        }
        
        guard let success = json["success"] as? Bool, success,
              let remoteFilepath = json["filepath"] as? String,
              let title = json["title"] as? String else {
            throw YTDLPError.downloadFailed
        }
        
        DispatchQueue.main.async {
            self.statusMessage = "Transferring file..."
            self.downloadProgress = 0.5
        }
        
        // Now fetch the actual file from the server
        let fileURL = baseURL.appendingPathComponent("file")
        var fileComponents = URLComponents(url: fileURL, resolvingAgainstBaseURL: true)!
        fileComponents.queryItems = [URLQueryItem(name: "path", value: remoteFilepath)]
        
        var fileRequest = URLRequest(url: fileComponents.url!)
        fileRequest.timeoutInterval = 300
        
        let (fileData, fileResponse) = try await URLSession.shared.data(for: fileRequest)
        
        guard let fileHttpResponse = fileResponse as? HTTPURLResponse,
              fileHttpResponse.statusCode == 200 else {
            throw YTDLPError.serverError("Failed to transfer file from server")
        }
        
        // Save to local documents
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let youtubeFolder = documentsPath.appendingPathComponent("YouTube Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: youtubeFolder, withIntermediateDirectories: true)
        
        let cleanTitle = title.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let ext = URL(fileURLWithPath: remoteFilepath).pathExtension
        let localFileURL = youtubeFolder.appendingPathComponent("\(cleanTitle).\(ext.isEmpty ? "m4a" : ext)")
        
        try? FileManager.default.removeItem(at: localFileURL)
        try fileData.write(to: localFileURL)
        
        DispatchQueue.main.async {
            self.statusMessage = "Download complete!"
            self.downloadProgress = 1.0
        }
        
        return (localFileURL, title)
    }
    
    enum YTDLPError: Error, LocalizedError {
        case serverNotRunning
        case serverError(String)
        case parseError
        case downloadFailed
        
        var errorDescription: String? {
            switch self {
            case .serverNotRunning:
                return "Python server is not running. Please start the server first."
            case .serverError(let message):
                return "Server error: \(message)"
            case .parseError:
                return "Failed to parse server response"
            case .downloadFailed:
                return "Download failed"
            }
        }
    }
}

// MARK: - Alternative: Direct yt-dlp execution (for macOS or jailbroken iOS)

extension PythonYTDLPService {
    /// Try to run yt-dlp directly via command line (macOS only)
    func downloadAudioDirect(url: String, outputDir: String) async throws -> (URL, String) {
        #if os(macOS)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                
                let outputTemplate = "\(outputDir)/%(title)s.%(ext)s"
                
                process.arguments = [
                    "yt-dlp",
                    "-f", "bestaudio",
                    "-o", outputTemplate,
                    "--print", "after_move:filepath",
                    "--no-playlist",
                    url
                ]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    
                    if process.terminationStatus == 0 {
                        // Last line should be the filepath
                        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                        if let filepath = lines.last, !filepath.isEmpty {
                            let fileURL = URL(fileURLWithPath: filepath)
                            let title = fileURL.deletingPathExtension().lastPathComponent
                            continuation.resume(returning: (fileURL, title))
                        } else {
                            continuation.resume(throwing: YTDLPError.downloadFailed)
                        }
                    } else {
                        continuation.resume(throwing: YTDLPError.serverError(output))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        #else
        throw YTDLPError.serverError("Direct yt-dlp execution not available on iOS")
        #endif
    }
}
