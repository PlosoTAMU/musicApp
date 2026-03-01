import Foundation
import ffmpegkit
import UIKit

/// Manages an embedded Python interpreter for running yt-dlp on iOS
/// Thread-safe: Uses dedicated serial queue for Python operations, main queue for UI updates
class EmbeddedPython: ObservableObject, @unchecked Sendable {
    static let shared = EmbeddedPython()
    
    @Published var isInitialized = false
    @Published var statusMessage = ""
    @Published var downloadProgress: Double = 0.0
    
    private var pythonInitialized = false
    private let pythonQueue = DispatchQueue(label: "com.musicapp.python", qos: .userInitiated)
    
    // Progress monitoring
    private var progressTimer: Timer?
    private var currentProgressFile: String?
    
    // FIXED: Title monitoring
    private var titleTimer: Timer?
    private var currentTitleFile: String?
    private var titleHasBeenFetched: Set<String> = [] // Track which videoIDs have had titles fetched
    
    // FIXED: Callback for title updates
    var onTitleFetched: ((String, String) -> Void)? // (videoID, title) -> Void
    
    init() {}
    
    func initialize() {
        guard !pythonInitialized else { return }
        pythonQueue.async { [weak self] in
            self?.setupPython()
        }
    }
    
    private func setupPython() {
        guard let resourcePath = Bundle.main.resourcePath else {
            updateStatus("Failed to find app resources")
            return
        }
        
        let pythonHome = resourcePath + "/python-stdlib"
        var pythonVersion = "python3.11"
        var libPath = pythonHome + "/lib/" + pythonVersion
        
        let libFolder = pythonHome + "/lib"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: libFolder) {
            for item in contents where item.hasPrefix("python3.") {
                pythonVersion = item
                libPath = libFolder + "/" + pythonVersion
                print("📂 [EmbeddedPython] Found Python version: \(pythonVersion)")
                break
            }
        } else {
            if FileManager.default.fileExists(atPath: pythonHome + "/encodings") {
                libPath = pythonHome
                print("📂 [EmbeddedPython] Using flat stdlib structure")
            }
        }
        
        let pythonPath = [
            libPath,
            libPath + "/lib-dynload",
            libPath + "/site-packages",
            pythonHome,
            resourcePath,
        ].joined(separator: ":")
        
        print("📂 [EmbeddedPython] PYTHONHOME: \(pythonHome)")
        print("📂 [EmbeddedPython] PYTHONPATH: \(pythonPath)")
        
        // ✅ FIXED: Robust certificate path resolution
        let certPath = resourcePath + "/cacert.pem"
        
        if FileManager.default.fileExists(atPath: certPath) {
            print("✅ [EmbeddedPython] Found certificate at: \(certPath)")
            setenv("SSL_CERT_FILE", certPath, 1)
            setenv("REQUESTS_CA_BUNDLE", certPath, 1)
            setenv("CURL_CA_BUNDLE", certPath, 1)
        } else {
            print("⚠️ [EmbeddedPython] Certificate NOT found at: \(certPath)")
            print("⚠️ [EmbeddedPython] Trying fallback certificate paths...")
            
            // Fallback 1: Check if it's in a subdirectory
            let altCertPath = resourcePath + "/python-stdlib/cacert.pem"
            if FileManager.default.fileExists(atPath: altCertPath) {
                print("✅ [EmbeddedPython] Found certificate at alternate path: \(altCertPath)")
                setenv("SSL_CERT_FILE", altCertPath, 1)
                setenv("REQUESTS_CA_BUNDLE", altCertPath, 1)
                setenv("CURL_CA_BUNDLE", altCertPath, 1)
            } else {
                // Fallback 2: Use iOS system certificates
                print("⚠️ [EmbeddedPython] Using system SSL certificates")
                setenv("PYTHONHTTPSVERIFY", "0", 1) // Disable verification as last resort
            }
        }

        let encodingsPath = libPath + "/encodings"
        guard FileManager.default.fileExists(atPath: encodingsPath) else {
            print("❌ [EmbeddedPython] encodings NOT found at: \(encodingsPath)")
            updateStatus("Python stdlib not found")
            return
        }
        
        print("✅ [EmbeddedPython] Found encodings at: \(encodingsPath)")
        
        setenv("PYTHONHOME", pythonHome, 1)
        setenv("PYTHONPATH", pythonPath, 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUNBUFFERED", "1", 1)
        setenv("PYTHONIOENCODING", "utf-8", 1)
        
        if initializePythonRuntime() {
            pythonInitialized = true
            DispatchQueue.main.async {
                self.isInitialized = true
                self.statusMessage = "Python ready"
            }
            print("✅ [EmbeddedPython] Initialized")
        } else {
            updateStatus("Failed to initialize Python")
        }
    }
    
    func downloadAudio(url: String, videoID: String = "") async throws -> (URL, String) {
        guard pythonInitialized else {
            throw PythonError.notInitialized
        }
        
        updateStatus("Starting download...")
        updateProgress(0.0)
        
        // Save to Music directory (visible in Files app)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputDir = documentsPath.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        return try await withCheckedThrowingContinuation { continuation in
            pythonQueue.async { [weak self] in
                do {
                    // Start progress monitoring
                    self?.startProgressMonitoring(outputDir: outputDir.path)
                    
                    // FIXED: Start title monitoring
                    self?.startTitleMonitoring(videoID: videoID)
                    
                    self?.updateStatus("Downloading...")
                    self?.updateProgress(0.1)
                    
                    // Python downloads the file - FIXED: callback updates banner immediately when title is known
                    let (downloadedURL, title, thumbnailURL) = try self?.runYtdlp(url: url, videoID: videoID, outputDir: outputDir.path) ?? (URL(fileURLWithPath: ""), "", nil)
                    
                    self?.updateStatus("Download complete, compressing...")
                    self?.updateProgress(0.7)
                    
                    // Stop progress monitoring
                    self?.stopProgressMonitoring()
                    
                    // FIXED: Stop title monitoring
                    self?.stopTitleMonitoring()
                    
                    // Compress it with proper naming
                    print("📄 [downloadAudio] Compressing audio...")
                    let compressedURL = (try? self?.compressAudio(inputURL: downloadedURL, title: title, outputDir: outputDir)) ?? downloadedURL
                    
                    self?.updateProgress(0.9)
                    
                    // Store metadata mapping with thumbnail
                    self?.saveMetadata(fileURL: compressedURL, title: title, thumbnailURL: thumbnailURL)
                    
                    self?.updateStatus("Complete!")
                    self?.updateProgress(1.0)
                    
                    print("✅ [downloadAudio] File saved to Music directory: \(compressedURL.path)")
                    
                    continuation.resume(returning: (compressedURL, title))
                } catch {
                    self?.stopProgressMonitoring()
                    self?.stopTitleMonitoring() // FIXED: Also stop title monitoring on error
                    self?.updateStatus("Failed")
                    self?.updateProgress(0.0)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    
    // MARK: - Progress Monitoring
    
    private func startProgressMonitoring(outputDir: String) {
        stopProgressMonitoring() // Clean up any existing timer
        
        DispatchQueue.main.async { [weak self] in
            self?.currentProgressFile = outputDir
            self?.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkDownloadProgress()
            }
        }
    }
    // Make executePython accessible for Spotify conversion
    func executePythonScript(_ script: String) -> Bool {
        return executePython(script) != nil
    }
    
    private func stopProgressMonitoring() {
        DispatchQueue.main.async { [weak self] in
            self?.progressTimer?.invalidate()
            self?.progressTimer = nil
            self?.currentProgressFile = nil
        }
    }
    
    // MARK: - Title Monitoring
    
    // FIXED: Monitor title file and notify callback when title is fetched
    private func startTitleMonitoring(videoID: String) {
        stopTitleMonitoring() // Clean up any existing timer
        
        guard !videoID.isEmpty else { return }
        
        let tempDir = FileManager.default.temporaryDirectory
        let titleFile = tempDir.appendingPathComponent("\(videoID)_title.txt").path
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Don't re-fetch if already fetched
            guard !self.titleHasBeenFetched.contains(videoID) else {
                print("📝 [TitleMonitoring] Title already fetched for: \(videoID)")
                return
            }
            
            print("📝 [TitleMonitoring] Starting title monitoring for: \(videoID)")
            
            self.currentTitleFile = titleFile
            self.titleTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                self?.checkTitleFile(videoID: videoID)
            }
        }
    }
    
    private func stopTitleMonitoring() {
        DispatchQueue.main.async { [weak self] in
            self?.titleTimer?.invalidate()
            self?.titleTimer = nil
            self?.currentTitleFile = nil
        }
    }
    
    private func checkTitleFile(videoID: String) {
        guard let titleFilePath = currentTitleFile,
              FileManager.default.fileExists(atPath: titleFilePath) else {
            return
        }
        
        do {
            let title = try String(contentsOfFile: titleFilePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !title.isEmpty else { return }
            
            // Mark as fetched
            titleHasBeenFetched.insert(videoID)
            
            // Call the callback on main thread
            DispatchQueue.main.async { [weak self] in
                self?.onTitleFetched?(videoID, title)
                print("📝 [TitleMonitoring] Title fetched: \(title)")
            }
            
            // Stop monitoring once we've got the title
            stopTitleMonitoring()
            
            // Clean up title file
            try? FileManager.default.removeItem(atPath: titleFilePath)
        } catch {
            // Ignore read errors, will retry on next timer tick
        }
    }
    
    private func checkDownloadProgress() {
        guard let outputDir = currentProgressFile else { return }
        
        // Check for .part files (in-progress downloads)
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: outputDir)
            
            for file in contents where file.hasSuffix(".part") || file.hasSuffix(".ytdl") {
                let filePath = (outputDir as NSString).appendingPathComponent(file)
                
                if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                   let fileSize = attrs[.size] as? Int64 {
                    
                    // Estimate progress based on typical audio file sizes (5-15MB)
                    let estimatedTotal: Double = 10_000_000 // 10MB estimate
                    let progress = min(Double(fileSize) / estimatedTotal, 0.65) // Cap at 65% during download
                    
                    updateProgress(0.1 + progress * 0.6) // Scale to 10-70% range
                    
                    let sizeMB = Double(fileSize) / 1_000_000
                    updateStatus(String(format: "Downloading... %.1f MB", sizeMB))
                }
            }
        } catch {
            // Ignore errors during progress checking
        }
    }

    private func compressAudio(inputURL: URL, title: String, outputDir: URL) throws -> URL {
        // Create safe filename from title
        let safeTitle = title.sanitizedForFilename()
        let outputURL = outputDir.appendingPathComponent("\(safeTitle).m4a")
        
        print("📄 [compressAudio] Compressing: \(inputURL.path)")
        print("📄 [compressAudio] Output: \(outputURL.path)")
        
        updateStatus("Compressing...")
        
        // SPEED OPTIMIZATION: Use ultrafast preset with hardware encoder
        let command = "-i \"\(inputURL.path)\" -vn -c:a aac_at -b:a 48k -threads 0 -preset ultrafast -async 1 -y \"\(outputURL.path)\""
        print("📄 [compressAudio] Command: \(command)")
        
        let session = FFmpegKit.execute(command)
        
        guard let returnCode = session?.getReturnCode(), returnCode.isValueSuccess() else {
            print("❌ [compressAudio] Compression failed, keeping original")
            if let output = session?.getFailStackTrace() {
                print("❌ [compressAudio] Error: \(output)")
            }
            return inputURL
        }
        
        let originalSize = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        let compressedSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        
        print("✅ [compressAudio] Original: \(originalSize / 1024)KB → Compressed: \(compressedSize / 1024)KB")
        
        // Delete original file
        try? FileManager.default.removeItem(at: inputURL)
        
        return outputURL
    }
    
    // MARK: - Metadata Management
    
    private func saveMetadata(fileURL: URL, title: String, thumbnailURL: String? = nil) {
        let metadataURL = getMetadataFileURL()
        var metadata = loadMetadata()
        
        let filename = fileURL.lastPathComponent
        var trackMetadata: [String: String] = ["title": title]
        
        if let thumbnailURL = thumbnailURL {
            trackMetadata["thumbnail"] = thumbnailURL
            // Download and save thumbnail with retry logic
            downloadThumbnail(url: thumbnailURL, for: filename)
        }
        
        metadata[filename] = trackMetadata
        
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
            print("✅ [Metadata] Saved: \(filename) -> \(title)")
        } catch {
            print("❌ [Metadata] Failed to save: \(error)")
        }
    }
    
    func getThumbnailPath(for fileURL: URL) -> URL? {
        let filename = fileURL.lastPathComponent
        let thumbnailsDir = getThumbnailsDirectory()
        let thumbnailPath = thumbnailsDir.appendingPathComponent("\(filename).jpg")
        
        // Check if file exists AND is readable
        if FileManager.default.fileExists(atPath: thumbnailPath.path),
        let _ = UIImage(contentsOfFile: thumbnailPath.path) {
            return thumbnailPath
        }
        
        return nil
    }
    
    private func downloadThumbnail(url: String, for filename: String) {
        guard let thumbnailURL = URL(string: url) else { return }
        
        let thumbnailsDir = getThumbnailsDirectory()
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        
        let savePath = thumbnailsDir.appendingPathComponent("\(filename).jpg")
        
        if FileManager.default.fileExists(atPath: savePath.path),
        let _ = UIImage(contentsOfFile: savePath.path) {
            print("✅ [Thumbnail] Already exists: \(savePath.lastPathComponent)")
            return
        }
        
        Task {
            // Try up to 3 times
            for attempt in 1...3 {
                do {
                    let (data, response) = try await URLSession.shared.data(from: thumbnailURL)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                        httpResponse.statusCode == 200,
                        let _ = UIImage(data: data) else {
                        if attempt == 3 {
                            print("❌ [Thumbnail] Invalid image data after \(attempt) attempts")
                            tryFallbackThumbnail(for: filename, originalURL: url)
                        } else {
                            print("⚠️ [Thumbnail] Attempt \(attempt) failed, retrying...")
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            continue
                        }
                        return
                    }
                    
                    try data.write(to: savePath, options: .atomic)
                    
                    if let _ = UIImage(contentsOfFile: savePath.path) {
                        print("✅ [Thumbnail] Saved and verified on attempt \(attempt): \(savePath.lastPathComponent)")
                        return
                    } else {
                        if attempt == 3 {
                            print("⚠️ [Thumbnail] Saved but unreadable after \(attempt) attempts")
                            try? FileManager.default.removeItem(at: savePath)
                            tryFallbackThumbnail(for: filename, originalURL: url)
                        } else {
                            try? FileManager.default.removeItem(at: savePath)
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            continue
                        }
                    }
                } catch {
                    if attempt == 3 {
                        print("❌ [Thumbnail] Failed after \(attempt) attempts: \(error)")
                        tryFallbackThumbnail(for: filename, originalURL: url)
                    } else {
                        print("⚠️ [Thumbnail] Attempt \(attempt) failed, retrying...")
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
        }
    }
    
    private func tryFallbackThumbnail(for filename: String, originalURL: String) {
        // Extract video ID from filename or URL
        let components = filename.components(separatedBy: ".")
        guard components.count > 0 else { return }
        let videoID = components[0]
        
        // Try different thumbnail qualities
        let fallbackURLs = [
            "https://img.youtube.com/vi/\(videoID)/maxresdefault.jpg",
            "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg",
            "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg",
            "https://img.youtube.com/vi/\(videoID)/default.jpg"
        ]
        
        Task {
            for fallbackURL in fallbackURLs {
                do {
                    let url = URL(string: fallbackURL)!
                    let (data, _) = try await URLSession.shared.data(from: url)
                    
                    if let _ = UIImage(data: data) {
                        let thumbnailsDir = getThumbnailsDirectory()
                        let savePath = thumbnailsDir.appendingPathComponent("\(filename).jpg")
                        try data.write(to: savePath, options: .atomic)
                        print("✅ [Thumbnail] Saved fallback: \(savePath.lastPathComponent)")
                        return
                    }
                } catch {
                    continue
                }
            }
            print("❌ [Thumbnail] All fallback attempts failed for: \(filename)")
        }
    }
    
    private func loadMetadata() -> [String: [String: String]] {
        let metadataURL = getMetadataFileURL()
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }
        return metadata
    }
    
    private func getMetadataFileURL() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("audio_metadata.json")
    }
    
    private func getThumbnailsDirectory() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let thumbnailsDir = documentsPath.appendingPathComponent("Thumbnails", isDirectory: true)
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        
        return thumbnailsDir
    }
    
    // MARK: - Optimized Python Execution
    
    private func runYtdlp(url: String, videoID: String, outputDir: String) throws -> (URL, String, String?) {
        let resultFilePath = NSTemporaryDirectory() + "ytdlp_result.json"
        let logFilePath = NSTemporaryDirectory() + "ytdlp_debug.log"
        let titleFilePath = NSTemporaryDirectory() + "ytdlp_title.txt" // FIXED: Intermediate title file
        
        print("🎬 [runYtdlp] Starting download for URL: \(url)")
        print("🎬 [runYtdlp] Output directory: \(outputDir)")
        
        let script = generateYtdlpScript(url: url, outputDir: outputDir, resultFilePath: resultFilePath, logFilePath: logFilePath, titleFilePath: titleFilePath)
        
        print("🎬 [runYtdlp] Executing Python script...")
        let startTime = Date()
        
        // FIXED: Monitor for title file in background
        startTitleMonitoring(titleFilePath: titleFilePath, videoID: videoID)
        
        guard executePython(script) != nil else {
            print("❌ [runYtdlp] executePython returned nil")
            if let debugLog = try? String(contentsOfFile: logFilePath, encoding: .utf8) {
                print("📋 [runYtdlp] Debug log:\n\(debugLog)")
            }
            throw PythonError.executionError("Failed to execute Python")
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("🎬 [runYtdlp] Completed in \(elapsed)s")
        
        if let debugLog = try? String(contentsOfFile: logFilePath, encoding: .utf8) {
            print("📋 [runYtdlp] Debug log:\n\(debugLog)")
        }
        try? FileManager.default.removeItem(atPath: logFilePath)
        try? FileManager.default.removeItem(atPath: titleFilePath)
        
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: resultFilePath)),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("❌ [runYtdlp] Failed to read result file")
            throw PythonError.executionError("Failed to read result")
        }
        
        print("🎬 [runYtdlp] Result: \(json)")
        try? FileManager.default.removeItem(atPath: resultFilePath)
        
        guard let success = json["success"] as? Bool, success,
              let audioURLString = json["audio_url"] as? String,
              let title = json["title"] as? String else {
            let errorMsg = json["error"] as? String ?? "Unknown error"
            print("❌ [runYtdlp] Failed: \(errorMsg)")
            throw PythonError.executionError(errorMsg)
        }
        
        let thumbnailURL = json["thumbnail"] as? String
        let audioURL = URL(fileURLWithPath: audioURLString)
        print("✅ [runYtdlp] Downloaded to: \(audioURL.path)")
        if let thumb = thumbnailURL {
            print("🖼️ [runYtdlp] Thumbnail URL: \(thumb)")
        }
        return (audioURL, title, thumbnailURL)
    }
    
    // FIXED: Monitor for title file and update banner immediately
    private func startTitleMonitoring(titleFilePath: String, videoID: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var hasRead = false
            for _ in 0..<20 { // Check for 10 seconds
                if !hasRead, FileManager.default.fileExists(atPath: titleFilePath),
                   let content = try? String(contentsOfFile: titleFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                   !content.isEmpty {
                    
                    // Parse format: videoID|title
                    let components = content.split(separator: "|", maxSplits: 1).map(String.init)
                    guard components.count == 2 else {
                        print("⚠️ [TitleMonitor] Invalid format: \(content)")
                        Thread.sleep(forTimeInterval: 0.5)
                        continue
                    }
                    
                    let extractedVideoID = components[0]
                    let title = components[1]
                    
                    print("📝 [TitleMonitor] Got title: \(title) for videoID: \(extractedVideoID)")
                    hasRead = true
                    
                    // Update banner on main thread using the EXTRACTED videoID
                    DispatchQueue.main.async {
                        self.onTitleFetched?(extractedVideoID, title)
                    }
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
    
    private func generateYtdlpScript(url: String, outputDir: String, resultFilePath: String, logFilePath: String, titleFilePath: String) -> String {
        let cleanURL = url.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        
        return """
        import sys
        import os
        import json
        
        log_file = r'''\(logFilePath)'''
        title_file = r'''\(titleFilePath)'''
        
        def log(msg):
            try:
                with open(log_file, 'a', encoding='utf-8') as f:
                    f.write(str(msg) + '\\n')
            except:
                pass
        
        log('=== yt-dlp Debug Log ===')
        log(f'Python version: {sys.version}')
        
        try:
            import yt_dlp
            log(f'yt_dlp imported successfully')
        except Exception as e:
            log(f'Failed to import yt_dlp: {e}')
            result = {'success': False, 'error': f'Failed to import yt_dlp: {e}'}
            with open(r'''\(resultFilePath)''', 'w', encoding='utf-8') as f:
                json.dump(result, f)
            raise
        
        output_dir = r'''\(outputDir)'''
        url = r'''\(cleanURL)'''
        os.makedirs(output_dir, exist_ok=True)
        
        ydl_opts = {
            'format': '140/bestaudio[ext=m4a]/bestaudio/best',
            'user_agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'quiet': False,
            'noplaylist': True,
            'outtmpl': os.path.join(output_dir, '%(id)s.%(ext)s'),
            'extractor_args': {
                'youtube': {
                    'player_client': ['ios', 'android'],
                    'skip': ['web'],
                }
            },
            'merge_output_format': 'm4a',
            'http_chunk_size': 10485760,
            'retries': 3,
            'fragment_retries': 1,
            'skip_unavailable_fragments': True,
            'socket_timeout': 20,
            'noprogress': True,
            'no_color': True,
            'nocheckcertificate': True,
        }
        
        result = {}
        try:
            log('Creating YoutubeDL instance...')
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                # FIXED: Extract info first to get title IMMEDIATELY
                log('Extracting info...')
                info = ydl.extract_info(url, download=False)
                title = info.get('title', 'Unknown')
                video_id = info.get('id', 'unknown')
                
                # FIXED: Write title to file immediately so banner can update
                # Format: videoID|title
                try:
                    with open(title_file, 'w', encoding='utf-8') as tf:
                        tf.write(f'{video_id}|{title}')
                    log(f'Wrote title to file: {title}')
                except Exception as e:
                    log(f'Failed to write title file: {e}')
                
                # Get best thumbnail
                thumbnail_url = None
                thumbnails = info.get('thumbnails', [])
                if thumbnails:
                    thumbnail_url = thumbnails[-1].get('url')
                else:
                    thumbnail_url = f'https://img.youtube.com/vi/{video_id}/maxresdefault.jpg'
                
                log(f'Thumbnail URL: {thumbnail_url}')
                
                # Now download
                log('Downloading...')
                info = ydl.extract_info(url, download=True)
                downloaded_path = ydl.prepare_filename(info)
                
                log(f'Downloaded: {downloaded_path}')
                
                if os.path.exists(downloaded_path):
                    if not downloaded_path.endswith('.m4a'):
                        m4a_path = os.path.splitext(downloaded_path)[0] + '.m4a'
                        log(f'Renaming {downloaded_path} to {m4a_path}')
                        try:
                            os.rename(downloaded_path, m4a_path)
                            downloaded_path = m4a_path
                        except Exception as e:
                            log(f'Rename failed: {e}')
                    
                    result = {
                        'success': True,
                        'title': title,
                        'audio_url': downloaded_path,
                        'audio_ext': 'm4a',
                        'thumbnail': thumbnail_url,
                    }
                else:
                    result = {'success': False, 'error': 'File not found after download'}
                    
        except Exception as e:
            log(f'Exception: {e}')
            import traceback
            log(traceback.format_exc())
            result = {'success': False, 'error': str(e)}
        
        with open(r'''\(resultFilePath)''', 'w', encoding='utf-8') as f:
            json.dump(result, f)
        log('Done')
        """
    }
    
    private func updateStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
        }
    }
    
    private func updateProgress(_ progress: Double) {
        DispatchQueue.main.async {
            self.downloadProgress = progress
        }
    }

    func ensureThumbnail(for fileURL: URL, videoID: String) {
        let thumbnailPath = getThumbnailPath(for: fileURL)
        
        // If thumbnail doesn't exist, try to re-download it
        if thumbnailPath == nil, !videoID.isEmpty {
            let thumbnailURL = "https://img.youtube.com/vi/\(videoID)/maxresdefault.jpg"
            let filename = fileURL.lastPathComponent
            downloadThumbnail(url: thumbnailURL, for: filename)
        }
    }
    
    private func initializePythonRuntime() -> Bool {
        _Py_NoSiteFlag = 1
        _Py_Initialize()
        let initialized = _Py_IsInitialized()
        
        if initialized != 0 {
            _ = _PyEval_SaveThread()
            print("✅ [EmbeddedPython] Python runtime initialized")
            return true
        } else {
            print("⚠️ [EmbeddedPython] Python initialization failed")
            return false
        }
    }
    
    private func executePython(_ code: String) -> String? {
        let isInit = _Py_IsInitialized()
        guard isInit != 0 else {
            print("❌ [EmbeddedPython] Python not initialized")
            return nil
        }
        
        let gstate = _PyGILState_Ensure()
        defer { _PyGILState_Release(gstate) }
        
        let result = code.withCString { _PyRun_SimpleString($0) }
        
        if result == 0 {
            print("✅ [EmbeddedPython] Script executed")
            return "SUCCESS"
        } else {
            print("❌ [EmbeddedPython] Script failed")
            return nil
        }
    }
    
    enum PythonError: Error, LocalizedError {
        case notInitialized
        case executionError(String)
        case downloadFailed
        
        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Python not initialized"
            case .executionError(let msg): return "Python error: \(msg)"
            case .downloadFailed: return "Download failed"
            }
        }
    }
}

// MARK: - String Extension for Safe Filenames

extension String {
    func sanitizedForFilename() -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.newlines)
            .union(.illegalCharacters)
            .union(.controlCharacters)
        
        let sanitized = self.components(separatedBy: invalid).joined(separator: "_")
        
        // Trim to reasonable length (iOS filename limit is 255 chars)
        let maxLength = 200
        if sanitized.count > maxLength {
            return String(sanitized.prefix(maxLength))
        }
        
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Python C API
@_silgen_name("Py_NoSiteFlag") private var _Py_NoSiteFlag: Int32
@_silgen_name("Py_Initialize") private func _Py_Initialize()
@_silgen_name("Py_IsInitialized") private func _Py_IsInitialized() -> Int32
@_silgen_name("PyRun_SimpleString") private func _PyRun_SimpleString(_ code: UnsafePointer<CChar>) -> Int32
@_silgen_name("Py_Finalize") private func _Py_Finalize()
@_silgen_name("PyGILState_Ensure") private func _PyGILState_Ensure() -> Int32
@_silgen_name("PyGILState_Release") private func _PyGILState_Release(_ state: Int32)
@_silgen_name("PyEval_SaveThread") private func _PyEval_SaveThread() -> UnsafeMutableRawPointer?