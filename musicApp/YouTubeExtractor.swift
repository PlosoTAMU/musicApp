import Foundation
import WebKit

/// YouTube audio extractor using authenticated WebView session
class YouTubeExtractor: NSObject, ObservableObject {
    static let shared = YouTubeExtractor()
    
    @Published var isLoggedIn = false
    @Published var needsLogin = false
    
    // Persistent WebView for maintaining login session
    private var webView: WKWebView?
    private var extractionCompletion: ((Result<VideoInfo, Error>) -> Void)?
    private var currentVideoID: String?
    
    // YouTube innertube API keys - these are PUBLIC keys embedded in YouTube's own clients
    // They are not secrets and are identical for all users. Extracted from YouTube JS/apps.
    private let iosAPIKey = "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc"
    private let androidAPIKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let tvAPIKey = "AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8"
    
    enum ExtractionError: Error, LocalizedError {
        case invalidURL
        case noVideoID
        case networkError(Error)
        case parsingError
        case noAudioStream
        case notLoggedIn
        case extractionTimeout
        
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid YouTube URL"
            case .noVideoID: return "Could not extract video ID"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .parsingError: return "Could not parse video info"
            case .noAudioStream: return "No audio stream found"
            case .notLoggedIn: return "Please log in to YouTube first"
            case .extractionTimeout: return "Extraction timed out"
            }
        }
    }
    
    override init() {
        super.init()
        // WebView must be created on main thread
        DispatchQueue.main.async { [weak self] in
            self?.setupWebView()
            self?.checkLoginStatus()
        }
    }
    
    private func setupWebView() {
        // Ensure we're on main thread for WKWebView
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setupWebView()
            }
            return
        }
        
        // Use persistent data store so cookies are saved between app launches
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView?.navigationDelegate = self
    }
    
    /// Check if we have YouTube cookies saved
    func checkLoginStatus() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let hasYouTubeCookies = cookies.contains { cookie in
                cookie.domain.contains("youtube.com") && 
                (cookie.name == "SID" || cookie.name == "SSID" || cookie.name == "LOGIN_INFO")
            }
            
            DispatchQueue.main.async {
                self?.isLoggedIn = hasYouTubeCookies
                print("🍪 [YouTubeExtractor] Logged in: \(hasYouTubeCookies)")
            }
        }
    }
    
    /// Get the WebView for displaying login UI
    func getLoginWebView() -> WKWebView {
        if webView == nil {
            setupWebView()
        }
        
        // Load YouTube login page
        if let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube") {
            webView?.load(URLRequest(url: url))
        }
        
        return webView!
    }
    
    /// Logout - clear all YouTube cookies
    func logout() {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let youtubeRecords = records.filter { $0.displayName.contains("youtube") || $0.displayName.contains("google") }
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: youtubeRecords) {
                DispatchQueue.main.async {
                    self.isLoggedIn = false
                    print("🍪 [YouTubeExtractor] Logged out")
                }
            }
        }
    }
    
    /// Extract video ID from various YouTube URL formats
    func extractVideoID(from urlString: String) -> String? {
        let patterns = [
            "(?:youtube\\.com/watch\\?v=|youtu\\.be/|youtube\\.com/embed/|youtube\\.com/v/|youtube\\.com/shorts/)([a-zA-Z0-9_-]{11})",
            "^([a-zA-Z0-9_-]{11})$"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: urlString, options: [], range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range(at: 1), in: urlString) {
                return String(urlString[range])
            }
        }
        return nil
    }
    
    /// Extract audio info using authenticated session
    func extractInfo(from urlString: String) async throws -> VideoInfo {
        guard let videoID = extractVideoID(from: urlString) else {
            throw ExtractionError.noVideoID
        }
        
        print("🎬 [YouTubeExtractor] Extracting: \(videoID)")
        
        var lastError: Error = ExtractionError.noAudioStream
        
        // Try the iOS client API first (usually works without strict auth)
        do {
            print("📱 [YouTubeExtractor] Trying iOS client...")
            return try await extractViaIOSClient(videoID: videoID)
        } catch {
            print("⚠️ [YouTubeExtractor] iOS client failed: \(error.localizedDescription)")
            lastError = error
        }
        
        // Try Android client (often less restricted)
        do {
            print("🤖 [YouTubeExtractor] Trying Android client...")
            return try await extractViaAndroidClient(videoID: videoID)
        } catch {
            print("⚠️ [YouTubeExtractor] Android client failed: \(error.localizedDescription)")
            lastError = error
        }
        
        // Try TV/embedded clients (least restricted)
        do {
            print("📺 [YouTubeExtractor] Trying TV/Embedded clients...")
            return try await extractViaTVClient(videoID: videoID)
        } catch {
            print("⚠️ [YouTubeExtractor] TV client failed: \(error.localizedDescription)")
            lastError = error
        }
        
        // Try music client as final fallback
        do {
            print("🎵 [YouTubeExtractor] Trying Music client...")
            return try await extractViaMusicClient(videoID: videoID)
        } catch {
            print("⚠️ [YouTubeExtractor] Music client failed: \(error.localizedDescription)")
            lastError = error
        }
        
        throw lastError
    }
    
    /// Extract using YouTube Music client
    private func extractViaMusicClient(videoID: String) async throws -> VideoInfo {
        let url = URL(string: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/120.0.6099.119 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": "1.20240617.01.00",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        return try await performExtraction(request: request, videoID: videoID, clientType: .music)
    }
    
    /// Extract using iOS YouTube client credentials
    private func extractViaIOSClient(videoID: String) async throws -> VideoInfo {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(iosAPIKey)&prettyPrint=false")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "19.29.1",
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "hl": "en",
                    "gl": "US",
                    "osName": "iOS",
                    "osVersion": "17.5.1.21F90"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        return try await performExtraction(request: request, videoID: videoID, clientType: .ios)
    }
    
    /// Extract using Android client (often less restricted)
    private func extractViaAndroidClient(videoID: String) async throws -> VideoInfo {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(androidAPIKey)&prettyPrint=false")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.youtube/19.29.37 (Linux; U; Android 14; en_US; sdk_gphone64_arm64 Build/UE1A.230829.036.A1) gzip", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "19.29.37",
                    "androidSdkVersion": 34,
                    "hl": "en",
                    "gl": "US",
                    "osName": "Android",
                    "osVersion": "14",
                    "platform": "MOBILE"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        return try await performExtraction(request: request, videoID: videoID, clientType: .android)
    }
    
    /// Extract using TV client (usually least restricted)
    private func extractViaTVClient(videoID: String) async throws -> VideoInfo {
        // Try embedded web player first (most permissive)
        do {
            return try await extractViaEmbeddedPlayer(videoID: videoID)
        } catch {
            print("⚠️ [YouTubeExtractor] Embedded player failed, trying TV client")
        }
        
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(tvAPIKey)&prettyPrint=false")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
                    "clientVersion": "2.0",
                    "hl": "en",
                    "gl": "US"
                ],
                "thirdParty": [
                    "embedUrl": "https://www.youtube.com"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        return try await performExtraction(request: request, videoID: videoID, clientType: .tv)
    }
    
    /// Extract using embedded web player - often bypasses restrictions
    private func extractViaEmbeddedPlayer(videoID: String) async throws -> VideoInfo {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/embed/\(videoID)", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "WEB_EMBEDDED_PLAYER",
                    "clientVersion": "1.20240620.00.00",
                    "hl": "en",
                    "gl": "US",
                    "clientScreen": "EMBED"
                ],
                "thirdParty": [
                    "embedUrl": "https://www.google.com"
                ]
            ],
            "playbackContext": [
                "contentPlaybackContext": [
                    "signatureTimestamp": 20073,
                    "html5Preference": "HTML5_PREF_WANTS"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        return try await performExtraction(request: request, videoID: videoID, clientType: .embedded)
    }
    
    /// Perform the actual extraction request
    private func performExtraction(request: URLRequest, videoID: String, clientType: YouTubeClientType = .android) async throws -> VideoInfo {
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExtractionError.networkError(NSError(domain: "HTTP", code: 0))
        }
        
        print("📡 [YouTubeExtractor] Response: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            throw ExtractionError.networkError(NSError(domain: "HTTP", code: httpResponse.statusCode))
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractionError.parsingError
        }
        
        // Check playability
        if let playabilityStatus = json["playabilityStatus"] as? [String: Any] {
            let status = playabilityStatus["status"] as? String ?? ""
            
            if status == "LOGIN_REQUIRED" {
                DispatchQueue.main.async { self.needsLogin = true }
                throw ExtractionError.notLoggedIn
            }
            
            if status != "OK" {
                let reason = playabilityStatus["reason"] as? String ?? "Unknown error"
                print("❌ [YouTubeExtractor] Playability: \(status) - \(reason)")
                throw ExtractionError.parsingError
            }
        }
        
        // Get video details
        guard let videoDetails = json["videoDetails"] as? [String: Any] else {
            throw ExtractionError.parsingError
        }
        
        let title = videoDetails["title"] as? String ?? "Unknown"
        let author = videoDetails["author"] as? String ?? "Unknown"
        let durationStr = videoDetails["lengthSeconds"] as? String ?? "0"
        let duration = Int(durationStr) ?? 0
        
        // Get streaming data
        guard let streamingData = json["streamingData"] as? [String: Any] else {
            throw ExtractionError.noAudioStream
        }
        
        // Find best audio format
        var audioURL: URL? = nil
        
        if let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] {
            let audioFormats = adaptiveFormats
                .filter { ($0["mimeType"] as? String)?.contains("audio") == true }
                .sorted { ($0["bitrate"] as? Int ?? 0) > ($1["bitrate"] as? Int ?? 0) }
            
            for format in audioFormats {
                if let urlStr = format["url"] as? String {
                    audioURL = URL(string: urlStr)
                    let bitrate = format["bitrate"] as? Int ?? 0
                    print("🎵 [YouTubeExtractor] Audio: \(bitrate) bps")
                    break
                }
            }
        }
        
        // Fallback to regular formats
        if audioURL == nil, let formats = streamingData["formats"] as? [[String: Any]] {
            if let format = formats.first, let urlStr = format["url"] as? String {
                audioURL = URL(string: urlStr)
            }
        }
        
        guard let finalURL = audioURL else {
            throw ExtractionError.noAudioStream
        }
        
        print("✅ [YouTubeExtractor] Success: \(title)")
        
        return VideoInfo(
            title: title,
            author: author,
            duration: duration,
            audioURL: finalURL,
            clientType: clientType
        )
    }
    
    /// Completion handler version
    static func extractVideoInfo(from url: String, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        Task {
            do {
                let info = try await YouTubeExtractor.shared.extractInfo(from: url)
                DispatchQueue.main.async { completion(.success(info)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}

// MARK: - WKNavigationDelegate
extension YouTubeExtractor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Check if we landed on YouTube after login
        if let url = webView.url?.absoluteString, url.contains("youtube.com") && !url.contains("accounts.google") {
            checkLoginStatus()
        }
    }
}