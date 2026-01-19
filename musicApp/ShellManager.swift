import Foundation
import PythonKit

// Video info structure for YouTube extraction
struct VideoInfo {
    let title: String
    let author: String
    let duration: Int
    let audioURL: URL
    let clientType: YouTubeClientType
    
    init(title: String, author: String, duration: Int, audioURL: URL, clientType: YouTubeClientType = .android) {
        self.title = title
        self.author = author
        self.duration = duration
        self.audioURL = audioURL
        self.clientType = clientType
    }
}

enum YouTubeClientType {
    case ios
    case android
    case tv
    case embedded
    case music
    
    var userAgent: String {
        switch self {
        case .ios:
            return "com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)"
        case .android:
            return "com.google.android.youtube/19.29.37 (Linux; U; Android 14; en_US; sdk_gphone64_arm64 Build/UE1A.230829.036.A1) gzip"
        case .tv:
            return "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
        case .embedded:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        case .music:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/120.0.6099.119 Mobile/15E148 Safari/604.1"
        }
    }
}

class ShellManager: ObservableObject {
    static let shared = ShellManager()
    
    @Published var isReady = false
    @Published var output: String = ""
    
    private var pythonInitialized = false
    
    init() {
        setupPython()
    }
    
    private func setupPython() {
        print("🐍 [Shell] Setting up Python environment...")
        
        guard let bundlePath = Bundle.main.resourcePath else {
            print("❌ [Shell] Could not find bundle path")
            return
        }
        
        print("📍 [Shell] Bundle: \(bundlePath)")
        
        // Check what's in Python-stdlib
        let pythonStdlibBase = "\(bundlePath)/Python-stdlib"
        print("📦 [Shell] Checking: \(pythonStdlibBase)")
        
        if FileManager.default.fileExists(atPath: pythonStdlibBase) {
            print("✅ [Shell] Python-stdlib folder exists")
            
            let libPath = "\(pythonStdlibBase)/lib"
            if FileManager.default.fileExists(atPath: libPath) {
                print("✅ [Shell] lib folder exists")
                
                if let libContents = try? FileManager.default.contentsOfDirectory(atPath: libPath) {
                    print("📦 [Shell] Contents of lib/: \(libContents)")
                }
            } else {
                print("❌ [Shell] lib folder NOT found at: \(libPath)")
            }
        } else {
            print("❌ [Shell] Python-stdlib folder NOT found!")
            print("⚠️  [Shell] Is it added to Xcode as a folder reference (blue folder)?")
            return
        }
        
        // Auto-detect Python version
        let libPath = "\(pythonStdlibBase)/lib"
        var pythonStdlibPath = ""
        
        if let libContents = try? FileManager.default.contentsOfDirectory(atPath: libPath) {
            for item in libContents {
                if item.hasPrefix("python3") {
                    pythonStdlibPath = "\(libPath)/\(item)"
                    print("✅ [Shell] Found Python: \(item)")
                    break
                }
            }
        }
        
        // Fallback paths
        if pythonStdlibPath.isEmpty {
            for version in ["python3.9", "python3.11", "python3.12", "python3.10"] {
                let testPath = "\(libPath)/\(version)"
                if FileManager.default.fileExists(atPath: testPath) {
                    pythonStdlibPath = testPath
                    print("✅ [Shell] Found \(version)")
                    break
                }
            }
        }
        
        let pythonGroupPath = "\(bundlePath)/python-group"
        let sitePackagesPath = "\(pythonGroupPath)/site-packages"
        
        print("📍 [Shell] Python stdlib: \(pythonStdlibPath)")
        print("📍 [Shell] Site packages: \(sitePackagesPath)")
        
        // Verify stdlib exists
        guard !pythonStdlibPath.isEmpty && FileManager.default.fileExists(atPath: pythonStdlibPath) else {
            print("❌ [Shell] Python stdlib not found!")
            print("⚠️  [Shell] Expected python3.x folder in: \(libPath)")
            return
        }
        
        print("✅ [Shell] Found Python stdlib")
        
        // Verify encodings module specifically
        let encodingsPath = "\(pythonStdlibPath)/encodings"
        if FileManager.default.fileExists(atPath: encodingsPath) {
            print("✅ [Shell] Verified encodings module exists")
        } else {
            print("⚠️  [Shell] Warning: encodings module not found")
        }
        
        // Set environment variables
        let pythonHome = "\(bundlePath)/Python-stdlib"
        setenv("PYTHONHOME", pythonHome, 1)
        
        let pythonPath = "\(pythonStdlibPath):\(sitePackagesPath)"
        setenv("PYTHONPATH", pythonPath, 1)
        
        print("📍 [Shell] PYTHONHOME: \(pythonHome)")
        print("📍 [Shell] PYTHONPATH: \(pythonPath)")
        
        // Create stub modules BEFORE any Python imports in a writable location
        let stubsPath = createAppleSupportStubFiles()
        
        // Update PYTHONPATH to include stubs FIRST
        let fullPythonPath = "\(stubsPath):\(pythonStdlibPath):\(sitePackagesPath)"
        setenv("PYTHONPATH", fullPythonPath, 1)
        print("📍 [Shell] Updated PYTHONPATH with stubs: \(fullPythonPath)")
        
        // Initialize Python via PythonKit
        let sys = Python.import("sys")
        
        // Add stubs path FIRST so it takes priority
        sys.path.insert(0, stubsPath)
        sys.path.insert(1, pythonStdlibPath)
        sys.path.append(sitePackagesPath)
        
        print("✅ [Shell] Python initialized")
        
        // Also register stubs in sys.modules just in case
        createAppleSupportStubs()
        
        pythonInitialized = true
        
        // Verify yt-dlp is available
        verifyYTDLP()
    }
    
    private func createAppleSupportStubs() {
        print("🔧 [Shell] Creating Apple support stub modules in sys.modules...")
        
        // Use Python directly to create stub modules
        let sys = Python.import("sys")
        let types = Python.import("types")
        
        // Create _apple_support stub
        let appleSupport = types.ModuleType("_apple_support")
        sys.modules["_apple_support"] = appleSupport
        print("✅ [Shell] _apple_support stub registered")
        
        // Create os_log stub
        let osLog = types.ModuleType("os_log")
        sys.modules["os_log"] = osLog
        print("✅ [Shell] os_log stub registered")
        
        // Create _scproxy stub
        let scproxy = types.ModuleType("_scproxy")
        sys.modules["_scproxy"] = scproxy
        print("✅ [Shell] _scproxy stub registered")
        
        print("✅ [Shell] All stub modules created")
    }
    
    private func createAppleSupportStubFiles() -> String {
        print("🔧 [Shell] Creating Apple support stub files...")
        
        // Use Documents directory which is writable
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let stubsPath = documentsPath.appendingPathComponent("python_stubs")
        
        // Create stubs directory
        try? FileManager.default.createDirectory(at: stubsPath, withIntermediateDirectories: true)
        
        // Create _apple_support.py stub - minimal, no imports
        let appleSupport = """
        # Stub module for _apple_support (iOS compatibility)
        # Keep this minimal to avoid import loops
        
        def init_apple_support(*args, **kwargs):
            pass
        
        def init_streams(*args, **kwargs):
            pass
        
        def os_log_create(*args, **kwargs):
            return None
        
        def os_log_with_type(*args, **kwargs):
            pass
        """
        try? appleSupport.write(to: stubsPath.appendingPathComponent("_apple_support.py"), atomically: true, encoding: .utf8)
        
        // Create _scproxy.py stub
        let scproxy = """
        # Stub module for _scproxy (iOS compatibility)
        def _get_proxy_settings():
            return {}
        def _get_proxies():
            return {}
        """
        try? scproxy.write(to: stubsPath.appendingPathComponent("_scproxy.py"), atomically: true, encoding: .utf8)
        
        // Create os_log.py stub
        let osLog = """
        # Stub module for os_log (iOS compatibility)
        def os_log_create(*args, **kwargs):
            return None
        def os_log_with_type(*args, **kwargs):
            pass
        """
        try? osLog.write(to: stubsPath.appendingPathComponent("os_log.py"), atomically: true, encoding: .utf8)
        
        print("✅ [Shell] Stub files created at: \(stubsPath.path)")
        return stubsPath.path
    }

    private func verifyYTDLP() {
        // Skip verification to avoid stack overflow
        // yt-dlp will be imported when needed
        print("📦 [Shell] Skipping yt-dlp verification (will import on demand)")
        DispatchQueue.main.async {
            self.isReady = true
            print("✅ [Shell] Shell environment ready")
        }
    }
    
    func executeYTDLP(url: String, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        guard pythonInitialized else {
            print("❌ [Shell] Python not initialized")
            completion(.failure(ShellError.notInitialized))
            return
        }
        
        print("🔧 [Shell] Executing yt-dlp for URL: \(url)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Import yt-dlp directly - stubs should handle missing modules
                let yt_dlp = Python.import("yt_dlp")
                
                print("✅ [Shell] yt-dlp imported")
                
                // Configure options - minimal, quiet mode
                let ydl_opts: PythonObject = [
                    "format": PythonObject("bestaudio/best"),
                    "quiet": PythonObject(true),
                    "no_warnings": PythonObject(true),
                    "no_color": PythonObject(true),
                    "noprogress": PythonObject(true)
                ]
                
                // Create instance and extract info
                let ydl = yt_dlp.YoutubeDL(ydl_opts)
                let info = ydl.extract_info(PythonObject(url), download: PythonObject(false))
                
                // Parse results - use Python str() to safely convert
                let titleObj = info["title"]
                let uploaderObj = info["uploader"] 
                let durationObj = info["duration"]
                let urlObj = info["url"]
                
                // Convert to Swift types safely
                let title: String
                if titleObj != Python.None, let t = String(titleObj) {
                    title = t
                } else {
                    title = "Unknown"
                }
                
                let author: String
                if uploaderObj != Python.None, let a = String(uploaderObj) {
                    author = a
                } else {
                    author = "Unknown"
                }
                
                let duration: Int
                if durationObj != Python.None, let d = Int(durationObj) {
                    duration = d
                } else {
                    duration = 0
                }
                
                let urlString: String
                if urlObj != Python.None, let u = String(urlObj) {
                    urlString = u
                } else {
                    throw ShellError.invalidURL
                }
                
                print("✅ [Shell] Extraction complete: \(title)")
                
                guard let audioURL = URL(string: urlString) else {
                    throw ShellError.invalidURL
                }
                
                let videoInfo = VideoInfo(
                    title: title,
                    author: author,
                    duration: duration,
                    audioURL: audioURL
                )
                
                DispatchQueue.main.async {
                    completion(.success(videoInfo))
                }
                
            } catch {
                print("❌ [Shell] Execution failed: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // Download audio directly using yt-dlp
    func downloadAudioDirectly(url: String, outputPath: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard pythonInitialized else {
            print("❌ [Shell] Python not initialized")
            completion(.failure(ShellError.notInitialized))
            return
        }
        
        print("🔧 [Shell] Downloading audio with yt-dlp for URL: \(url)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Import yt-dlp directly
                let yt_dlp = Python.import("yt_dlp")
                
                // Configure options for direct download - no FFmpeg postprocessing
                // Just get the best audio format available
                let ydl_opts: PythonObject = [
                    "format": PythonObject("bestaudio/best"),
                    "outtmpl": PythonObject(outputPath),
                    "quiet": PythonObject(true),
                    "no_warnings": PythonObject(true),
                    "no_color": PythonObject(true),
                    "noprogress": PythonObject(true)
                ]
                
                // Create instance and download
                let ydl = yt_dlp.YoutubeDL(ydl_opts)
                let info = ydl.extract_info(PythonObject(url), download: PythonObject(true))
                
                // Get title safely
                let titleObj = info["title"]
                let title: String
                if titleObj != Python.None, let t = String(titleObj) {
                    title = t
                } else {
                    title = "Unknown"
                }
                
                print("✅ [Shell] Download complete: \(title)")
                
                DispatchQueue.main.async {
                    completion(.success(title))
                }
                
            } catch {
                print("❌ [Shell] Download failed: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}

enum ShellError: Error {
    case notInitialized
    case invalidURL
    case executionFailed
}
