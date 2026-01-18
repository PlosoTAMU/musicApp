import Foundation
import Network

class YouTubeDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    @Published var allowWiFi = false // User preference to allow Wi-Fi downloads
    
    // Vercel API endpoint
    private let apiBaseURL = "https://youtube-audio-api-six.vercel.app"
    
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    
    init() {
        setupNetworkMonitoring()
    }
    
    deinit {
        pathMonitor.cancel()
    }
    
    private func setupNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            // Only warn about Wi-Fi if user hasn't allowed it
            if !self.allowWiFi && path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.cellular) {
                DispatchQueue.main.async {
                    self.errorMessage = "Cellular connection required. Wi-Fi detected. Enable 'Allow Wi-Fi' to proceed."
                    self.isDownloading = false
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
    
    private func createCellularOnlyURLSession() -> URLSession {
        let config = URLSessionConfiguration.default
        
        // Only enforce cellular if Wi-Fi is not allowed
        if !allowWiFi {
            // Use multipath service type for better cellular routing
            config.multipathServiceType = .handover
            
            // Allow expensive paths (cellular data)
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = false
        }
        
        return URLSession(configuration: config)
    }
    
    private func createCellularOnlyConnection(to url: URL) -> NWConnection? {
        guard let host = url.host else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        
        // Create TCP parameters with cellular-only requirement
        let params = NWParameters.tcp
        params.requiredInterfaceType = .cellular
        params.prohibitExpensivePaths = false
        params.prohibitConstrainedPaths = false
        
        // Configure TLS if HTTPS
        if url.scheme == "https" {
            let tlsOptions = NWProtocolTLS.Options()
            params.defaultProtocolStack.applicationProtocols.insert(tlsOptions, at: 0)
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)))
        return NWConnection(to: endpoint, using: params)
    }
    
    private func checkCellularAvailability() -> Bool {
        // If Wi-Fi is allowed, skip cellular check
        if allowWiFi {
            return true
        }
        
        let path = pathMonitor.currentPath
        
        // Check if cellular is available
        guard path.usesInterfaceType(.cellular) else {
            DispatchQueue.main.async {
                self.errorMessage = "Cellular connection required. Please disable Wi-Fi, enable cellular data, or check 'Allow Wi-Fi'."
            }
            return false
        }
        
        // Fail fast if Wi-Fi is active
        if path.usesInterfaceType(.wifi) {
            DispatchQueue.main.async {
                self.errorMessage = "Cellular only mode: Wi-Fi must be disabled or check 'Allow Wi-Fi' to proceed."
            }
            return false
        }
        
        return true
    }
    
    func downloadAudio(from youtubeURL: String, completion: @escaping (Track?) -> Void) {
        // Check cellular availability first
        guard checkCellularAvailability() else {
            completion(nil)
            return
        }
        
        guard let encodedURL = youtubeURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid URL"
            }
            completion(nil)
            return
        }
        
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        
        let apiURL = URL(string: "\(apiBaseURL)/api/download?url=\(encodedURL)")!
        
        // Create cellular-only URL session
        let cellularSession = createCellularOnlyURLSession()
        
        cellularSession.dataTask(with: apiURL) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "Network error: \(error.localizedDescription)"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    self.errorMessage = "No data received"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                
                if let error = json?["error"] as? String {
                    DispatchQueue.main.async {
                        self.errorMessage = error
                        self.isDownloading = false
                    }
                    completion(nil)
                    return
                }
                
                guard let title = json?["title"] as? String,
                      let urlString = json?["url"] as? String,
                      let streamURL = URL(string: urlString) else {
                    DispatchQueue.main.async {
                        self.errorMessage = "Invalid response from server"
                        self.isDownloading = false
                    }
                    completion(nil)
                    return
                }
                
                self.downloadFile(from: streamURL, title: title, completion: completion)
                
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to parse response"
                    self.isDownloading = false
                }
                completion(nil)
            }
        }.resume()
    }
    
    private func downloadFile(from url: URL, title: String, completion: @escaping (Track?) -> Void) {
        // Create cellular-only URL session for download
        let cellularSession = createCellularOnlyURLSession()
        
        let downloadTask = cellularSession.downloadTask(with: url) { [weak self] localURL, response, error in
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
                    self.downloadProgress = 1.0
                    completion(track)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to save file: \(error.localizedDescription)"
                    self.isDownloading = false
                }
                completion(nil)
            }
        }
        
        downloadTask.resume()
    }
}