import Foundation
import WebKit
import CommonCrypto

/// YouTube audio extractor using authenticated WebView session
class YouTubeExtractor: NSObject, ObservableObject {
    static let shared = YouTubeExtractor()
    
    @Published var isLoggedIn = false
    @Published var needsLogin = false
    @Published var downloadProgress: Double = 0.0
    @Published var statusMessage: String = ""
    
    // Persistent WebView for maintaining login session AND downloading
    private var webView: WKWebView?
    private var downloadWebView: WKWebView?
    private var extractionCompletion: ((Result<VideoInfo, Error>) -> Void)?
    private var downloadCompletion: ((Result<(URL, String), Error>) -> Void)?
    private var currentVideoID: String?
    private var currentVideoTitle: String?
    private var messageHandler: WebViewMessageHandler?
    
    // YouTube innertube API keys - these are PUBLIC keys embedded in YouTube's own clients
    // They are not secrets and are identical for all users. Extracted from YouTube JS/apps.
    private let iosAPIKey = "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc"
    private let androidAPIKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let tvAPIKey = "AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8"
    
    // Cached SAPISID for authorization header
    private var cachedSAPISID: String?
    
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
            self?.setupDownloadWebView()
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
    
    /// Setup a dedicated WebView for downloading with JavaScript message handler
    private func setupDownloadWebView() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setupDownloadWebView()
            }
            return
        }
        
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        
        // Allow media playback without user action (needed for audio extraction)
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        
        // Create message handler for receiving download data from JS
        messageHandler = WebViewMessageHandler { [weak self] message in
            self?.handleDownloadMessage(message)
        }
        config.userContentController.add(messageHandler!, name: "downloadHandler")
        
        downloadWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        downloadWebView?.navigationDelegate = self
    }
    
    /// Check if we have YouTube cookies saved and sync them to HTTPCookieStorage
    func checkLoginStatus() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let youtubeCookies = cookies.filter { 
                $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
            }
            
            let hasYouTubeCookies = youtubeCookies.contains { cookie in
                cookie.name == "SID" || cookie.name == "SSID" || cookie.name == "LOGIN_INFO" ||
                cookie.name == "__Secure-1PSID" || cookie.name == "__Secure-3PSID"
            }
            
            // Always sync WKWebView cookies to HTTPCookieStorage
            if !youtubeCookies.isEmpty {
                print("🔄 [YouTubeExtractor] Syncing \(youtubeCookies.count) cookies from WKWebView to HTTPCookieStorage")
                for cookie in youtubeCookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
            }
            
            DispatchQueue.main.async {
                self?.isLoggedIn = hasYouTubeCookies
                print("🍪 [YouTubeExtractor] Logged in: \(hasYouTubeCookies)")
            }
        }
    }
    
    /// Sync cookies from WKWebView to HTTPCookieStorage (call before making requests)
    func syncCookies() async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let youtubeCookies = cookies.filter { 
                    $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
                }
                for cookie in youtubeCookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                print("🔄 [YouTubeExtractor] Synced \(youtubeCookies.count) cookies")
                continuation.resume()
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
                    self.cachedSAPISID = nil
                    // Also clear HTTPCookieStorage
                    if let cookies = HTTPCookieStorage.shared.cookies {
                        for cookie in cookies where cookie.domain.contains("youtube") || cookie.domain.contains("google") {
                            HTTPCookieStorage.shared.deleteCookie(cookie)
                        }
                    }
                    print("🍪 [YouTubeExtractor] Logged out")
                }
            }
        }
    }
    
    /// Get cookie string for requests
    private func getCookieString() -> String? {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return nil }
        let youtubeCookies = cookies.filter { $0.domain.contains("youtube.com") || $0.domain.contains(".google.com") }
        if youtubeCookies.isEmpty { return nil }
        return youtubeCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    
    /// Get SAPISID hash for authorization (required for authenticated API calls)
    private func getSAPISIDHash(origin: String) -> String? {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return nil }
        
        // Find SAPISID cookie
        guard let sapisid = cookies.first(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" })?.value else {
            return nil
        }
        
        // Create SAPISIDHASH: timestamp_sha1(timestamp + " " + SAPISID + " " + origin)
        let timestamp = Int(Date().timeIntervalSince1970)
        let input = "\(timestamp) \(sapisid) \(origin)"
        
        // SHA-1 hash
        guard let data = input.data(using: .utf8) else { return nil }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &hash)
        }
        let hashString = hash.map { String(format: "%02x", $0) }.joined()
        
        return "SAPISIDHASH \(timestamp)_\(hashString)"
    }
    
    /// Apply authentication to a request if logged in
    private func applyAuth(to request: inout URLRequest, origin: String) {
        // Debug: print all cookies we have
        if let allCookies = HTTPCookieStorage.shared.cookies {
            print("🍪 [YouTubeExtractor] Total cookies in storage: \(allCookies.count)")
            let ytCookies = allCookies.filter { $0.domain.contains("youtube") || $0.domain.contains("google") }
            print("🍪 [YouTubeExtractor] YouTube/Google cookies: \(ytCookies.count)")
            for cookie in ytCookies {
                print("   - \(cookie.name): \(cookie.domain)")
            }
        }
        
        if let cookies = getCookieString() {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
            print("🍪 [YouTubeExtractor] Applied \(cookies.count) chars of cookies")
        } else {
            print("⚠️ [YouTubeExtractor] No cookies to apply!")
        }
        
        if let authHeader = getSAPISIDHash(origin: origin) {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            print("🔐 [YouTubeExtractor] Applied SAPISIDHASH auth")
        } else {
            print("⚠️ [YouTubeExtractor] No SAPISID found for auth header")
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
        
        // Sync cookies from WKWebView before making requests
        await syncCookies()
        
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
        
        // Apply authentication if logged in
        applyAuth(to: &request, origin: "https://www.youtube.com")
        
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
        
        // Apply authentication if logged in
        applyAuth(to: &request, origin: "https://www.youtube.com")
        
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
        // Use a session configured to use cookies
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        
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
    
    /// Download audio data directly and return the local file URL
    func downloadAudioDirectly(from urlString: String) async throws -> (URL, String) {
        // First, try the WebView-based approach (uses real browser session)
        // This bypasses 403 issues because the WebView has the authenticated session
        print("📥 [YouTubeExtractor] Using WebView-based download (bypasses 403)...")
        
        return try await downloadAudioViaWebView(from: urlString)
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
    
    // MARK: - WebView-based Download (bypasses 403 by using browser session)
    
    /// Download audio by loading the YouTube page in WebView and extracting via JavaScript
    func downloadAudioViaWebView(from urlString: String) async throws -> (URL, String) {
        guard let videoID = extractVideoID(from: urlString) else {
            throw ExtractionError.noVideoID
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: ExtractionError.networkError(NSError(domain: "Self deallocated", code: 0)))
                    return
                }
                
                self.currentVideoID = videoID
                self.downloadCompletion = { result in
                    continuation.resume(with: result)
                }
                
                self.statusMessage = "Loading video page..."
                
                // Load the YouTube watch page in our download WebView
                let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
                self.downloadWebView?.load(URLRequest(url: watchURL))
            }
        }
    }
    
    /// Handle messages from JavaScript
    private func handleDownloadMessage(_ message: Any) {
        guard let dict = message as? [String: Any] else { return }
        
        if let type = dict["type"] as? String {
            switch type {
            case "progress":
                if let progress = dict["progress"] as? Double {
                    DispatchQueue.main.async {
                        self.downloadProgress = progress
                    }
                }
                
            case "status":
                if let status = dict["status"] as? String {
                    DispatchQueue.main.async {
                        self.statusMessage = status
                    }
                }
                
            case "title":
                if let title = dict["title"] as? String {
                    self.currentVideoTitle = title
                }
                
            case "audioData":
                // Audio data received as base64
                if let base64Data = dict["data"] as? String,
                   let audioData = Data(base64Encoded: base64Data) {
                    saveDownloadedAudio(audioData)
                }
                
            case "audioURL":
                // Got an audio URL to download
                if let urlString = dict["url"] as? String {
                    downloadFromExtractedURL(urlString)
                }
                
            case "error":
                if let error = dict["message"] as? String {
                    let completion = self.downloadCompletion
                    self.downloadCompletion = nil
                    DispatchQueue.main.async {
                        self.statusMessage = "Error: \(error)"
                        completion?(.failure(ExtractionError.parsingError))
                    }
                }
                
            default:
                break
            }
        }
    }
    
    /// Download from the URL extracted by JavaScript (using WebView's session)
    private func downloadFromExtractedURL(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            downloadCompletion?(.failure(ExtractionError.invalidURL))
            return
        }
        
        DispatchQueue.main.async {
            self.statusMessage = "Downloading audio..."
        }
        
        // Use JavaScript fetch within the WebView to download (maintains session)
        let js = """
        (async function() {
            try {
                window.webkit.messageHandlers.downloadHandler.postMessage({type: 'status', status: 'Fetching audio data...'});
                
                const response = await fetch('\(urlString)', {
                    credentials: 'include',
                    headers: {
                        'Range': 'bytes=0-'
                    }
                });
                
                if (!response.ok) {
                    window.webkit.messageHandlers.downloadHandler.postMessage({type: 'error', message: 'HTTP ' + response.status});
                    return;
                }
                
                const reader = response.body.getReader();
                const contentLength = response.headers.get('Content-Length');
                const total = contentLength ? parseInt(contentLength) : 0;
                let received = 0;
                const chunks = [];
                
                while(true) {
                    const {done, value} = await reader.read();
                    if (done) break;
                    chunks.push(value);
                    received += value.length;
                    if (total > 0) {
                        window.webkit.messageHandlers.downloadHandler.postMessage({
                            type: 'progress', 
                            progress: received / total
                        });
                    }
                }
                
                window.webkit.messageHandlers.downloadHandler.postMessage({type: 'status', status: 'Processing audio...'});
                
                const blob = new Blob(chunks);
                const arrayBuffer = await blob.arrayBuffer();
                const uint8Array = new Uint8Array(arrayBuffer);
                
                // Convert to base64 in chunks to avoid memory issues
                let binary = '';
                const chunkSize = 65536;
                for (let i = 0; i < uint8Array.length; i += chunkSize) {
                    const chunk = uint8Array.subarray(i, Math.min(i + chunkSize, uint8Array.length));
                    binary += String.fromCharCode.apply(null, chunk);
                }
                const base64 = btoa(binary);
                
                window.webkit.messageHandlers.downloadHandler.postMessage({
                    type: 'audioData',
                    data: base64
                });
                
            } catch(e) {
                window.webkit.messageHandlers.downloadHandler.postMessage({type: 'error', message: e.toString()});
            }
        })();
        """
        
        downloadWebView?.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("❌ [YouTubeExtractor] JS fetch error: \(error)")
            }
        }
    }
    
    /// Save the downloaded audio data to a file
    private func saveDownloadedAudio(_ data: Data) {
        let title = currentVideoTitle ?? "youtube_audio_\(Date().timeIntervalSince1970)"
        let cleanTitle = title.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let youtubeFolder = documentsPath.appendingPathComponent("YouTube Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: youtubeFolder, withIntermediateDirectories: true)
        
        let destinationURL = youtubeFolder.appendingPathComponent("\(cleanTitle).m4a")
        
        do {
            try? FileManager.default.removeItem(at: destinationURL)
            try data.write(to: destinationURL)
            
            print("✅ [YouTubeExtractor] Saved: \(destinationURL.lastPathComponent) (\(data.count) bytes)")
            
            let completion = self.downloadCompletion
            self.downloadCompletion = nil
            DispatchQueue.main.async {
                self.statusMessage = "Download complete!"
                self.downloadProgress = 1.0
                completion?(.success((destinationURL, title)))
            }
        } catch {
            print("❌ [YouTubeExtractor] Save error: \(error)")
            let completion = self.downloadCompletion
            self.downloadCompletion = nil
            DispatchQueue.main.async {
                completion?(.failure(error))
            }
        }
    }
}

// MARK: - WebView Message Handler
class WebViewMessageHandler: NSObject, WKScriptMessageHandler {
    let handler: (Any) -> Void
    
    init(handler: @escaping (Any) -> Void) {
        self.handler = handler
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        handler(message.body)
    }
}

// MARK: - WKNavigationDelegate
extension YouTubeExtractor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Check if this is the login webview
        if webView === self.webView {
            if let url = webView.url?.absoluteString, url.contains("youtube.com") && !url.contains("accounts.google") {
                checkLoginStatus()
            }
            return
        }
        
        // This is the download webview - inject extraction script
        if webView === self.downloadWebView {
            guard let url = webView.url?.absoluteString, url.contains("youtube.com/watch") else { return }
            
            print("📄 [YouTubeExtractor] Watch page loaded, extracting audio URL...")
            
            DispatchQueue.main.async {
                self.statusMessage = "Extracting audio..."
            }
            
            // JavaScript to extract audio URL from ytInitialPlayerResponse
            let extractionJS = """
            (function() {
                try {
                    // Get video title
                    var title = document.title.replace(' - YouTube', '').trim();
                    window.webkit.messageHandlers.downloadHandler.postMessage({type: 'title', title: title});
                    window.webkit.messageHandlers.downloadHandler.postMessage({type: 'status', status: 'Parsing video data...'});
                    
                    // Try to find ytInitialPlayerResponse
                    var playerResponse = null;
                    
                    // Method 1: Direct variable access
                    if (typeof ytInitialPlayerResponse !== 'undefined') {
                        playerResponse = ytInitialPlayerResponse;
                    }
                    
                    // Method 2: Parse from page scripts
                    if (!playerResponse) {
                        var scripts = document.getElementsByTagName('script');
                        for (var i = 0; i < scripts.length; i++) {
                            var text = scripts[i].textContent;
                            if (text && text.includes('ytInitialPlayerResponse')) {
                                var match = text.match(/ytInitialPlayerResponse\\s*=\\s*(\\{.+?\\});/s);
                                if (match) {
                                    try {
                                        playerResponse = JSON.parse(match[1]);
                                        break;
                                    } catch(e) {}
                                }
                            }
                        }
                    }
                    
                    // Method 3: Look for player config
                    if (!playerResponse && typeof ytplayer !== 'undefined' && ytplayer.config) {
                        playerResponse = ytplayer.config.args.player_response;
                        if (typeof playerResponse === 'string') {
                            playerResponse = JSON.parse(playerResponse);
                        }
                    }
                    
                    if (!playerResponse || !playerResponse.streamingData) {
                        window.webkit.messageHandlers.downloadHandler.postMessage({type: 'error', message: 'Could not find streaming data'});
                        return;
                    }
                    
                    var streamingData = playerResponse.streamingData;
                    var audioURL = null;
                    var bestBitrate = 0;
                    
                    // Check adaptiveFormats for audio
                    var formats = streamingData.adaptiveFormats || [];
                    for (var i = 0; i < formats.length; i++) {
                        var format = formats[i];
                        if (format.mimeType && format.mimeType.includes('audio')) {
                            var bitrate = format.bitrate || 0;
                            if (bitrate > bestBitrate && format.url) {
                                bestBitrate = bitrate;
                                audioURL = format.url;
                            }
                        }
                    }
                    
                    // Fallback to formats
                    if (!audioURL && streamingData.formats) {
                        for (var i = 0; i < streamingData.formats.length; i++) {
                            var format = streamingData.formats[i];
                            if (format.url) {
                                audioURL = format.url;
                                break;
                            }
                        }
                    }
                    
                    if (audioURL) {
                        window.webkit.messageHandlers.downloadHandler.postMessage({type: 'status', status: 'Starting download...'});
                        window.webkit.messageHandlers.downloadHandler.postMessage({type: 'audioURL', url: audioURL});
                    } else {
                        window.webkit.messageHandlers.downloadHandler.postMessage({type: 'error', message: 'No audio URL found in streaming data'});
                    }
                    
                } catch(e) {
                    window.webkit.messageHandlers.downloadHandler.postMessage({type: 'error', message: 'Extraction error: ' + e.toString()});
                }
            })();
            """
            
            webView.evaluateJavaScript(extractionJS) { _, error in
                if let error = error {
                    print("❌ [YouTubeExtractor] Extraction JS error: \(error)")
                }
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.downloadWebView {
            let completion = self.downloadCompletion
            self.downloadCompletion = nil
            DispatchQueue.main.async {
                self.statusMessage = "Navigation failed"
                completion?(.failure(error))
            }
        }
    }
}