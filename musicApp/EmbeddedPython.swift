import Foundation

/// Manages an embedded Python interpreter for running yt-dlp on iOS
/// 
/// SETUP INSTRUCTIONS:
/// 
/// 1. Download Python iOS Framework:
///    - Go to https://github.com/beeware/Python-Apple-support/releases
///    - Download Python-3.11-iOS-support.b1.tar.gz (or latest)
///    - Extract and add Python.xcframework to Xcode project
///    - Add python-stdlib folder to project as folder reference
///
/// 2. Download yt-dlp:
///    - pip download yt-dlp --no-deps -d ./packages
///    - Unzip the wheel file
///    - Add yt_dlp folder to Xcode project as folder reference
///
/// 3. Configure Xcode:
///    - Embed & Sign the Python.xcframework
///    - Ensure python-stdlib and yt_dlp are in "Copy Bundle Resources"
///
class EmbeddedPython: ObservableObject {
    static let shared = EmbeddedPython()
    
    @Published var isInitialized = false
    @Published var statusMessage = ""
    @Published var downloadProgress: Double = 0.0
    
    private var pythonInitialized = false
    
    init() {
        // Python will be initialized on first use
    }
    
    /// Initialize Python interpreter - call at app launch
    func initialize() {
        guard !pythonInitialized else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setupPython()
        }
    }
    
    private func setupPython() {
        guard let resourcePath = Bundle.main.resourcePath else {
            updateStatus("Failed to find app resources")
            return
        }
        
        // Set up Python paths
        // PYTHONHOME should be the root containing the lib folder structure
        let pythonHome = resourcePath + "/python-stdlib"
        
        // Auto-detect Python version by looking for python3.X folder
        var pythonVersion = "python3.14"  // Default
        var libPath = pythonHome + "/lib/" + pythonVersion
        
        // Try to find the actual Python version folder
        let libFolder = pythonHome + "/lib"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: libFolder) {
            for item in contents where item.hasPrefix("python3.") {
                pythonVersion = item
                libPath = libFolder + "/" + pythonVersion
                print("📂 [EmbeddedPython] Found Python version: \(pythonVersion)")
                break
            }
        } else {
            // Maybe the stdlib is directly in python-stdlib (flat structure)
            if FileManager.default.fileExists(atPath: pythonHome + "/encodings") {
                libPath = pythonHome
                print("📂 [EmbeddedPython] Using flat stdlib structure")
            }
        }
        
        let pythonPath = [
            libPath,                           // Core stdlib including encodings
            libPath + "/lib-dynload",          // C extension modules
            libPath + "/site-packages",        // Any installed packages
            pythonHome,                        // Also include python-stdlib root
            resourcePath + "/yt_dlp",          // yt-dlp module
        ].joined(separator: ":")
        
        // Debug: Print paths to help troubleshoot
        print("📂 [EmbeddedPython] Resource path: \(resourcePath)")
        print("📂 [EmbeddedPython] PYTHONHOME: \(pythonHome)")
        print("📂 [EmbeddedPython] Lib path: \(libPath)")
        print("📂 [EmbeddedPython] PYTHONPATH: \(pythonPath)")
        
        // Check if encodings module exists
        let encodingsPath = libPath + "/encodings"
        if FileManager.default.fileExists(atPath: encodingsPath) {
            print("✅ [EmbeddedPython] Found encodings at: \(encodingsPath)")
        } else {
            print("❌ [EmbeddedPython] encodings NOT found at: \(encodingsPath)")
            print("❌ [EmbeddedPython] Please verify python-stdlib folder structure")
            
            // List what's actually in the folders to help debug
            if let homeContents = try? FileManager.default.contentsOfDirectory(atPath: pythonHome) {
                print("📂 [EmbeddedPython] python-stdlib contains: \(homeContents)")
            }
            if let libContents = try? FileManager.default.contentsOfDirectory(atPath: libPath) {
                print("📂 [EmbeddedPython] lib path contains: \(libContents.prefix(20))...")
            }
            
            updateStatus("Python stdlib not found - check setup")
            return
        }
        
        setenv("PYTHONHOME", pythonHome, 1)
        setenv("PYTHONPATH", pythonPath, 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUNBUFFERED", "1", 1)
        
        // The actual Python initialization happens via the C API
        // When Python.xcframework is properly linked, we can call Py_Initialize()
        
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
    
    /// Download audio using yt-dlp
    func downloadAudio(url: String) async throws -> (URL, String) {
        guard pythonInitialized else {
            throw PythonError.notInitialized
        }
        
        updateStatus("Starting download...")
        
        // Get output directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputDir = documentsPath.appendingPathComponent("YouTube Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let result = try self?.runYtdlp(url: url, outputDir: outputDir.path)
                    if let result = result {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: PythonError.downloadFailed)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func runYtdlp(url: String, outputDir: String) throws -> (URL, String) {
        // Result file path - Python will write the result here
        let resultFilePath = NSTemporaryDirectory() + "ytdlp_result.json"
        
        let script = """
        import sys
        import os
        import json

        # Ensure yt_dlp is in path
        yt_dlp_path = os.path.join(os.environ.get('PYTHONPATH', '').split(':')[0], '..', 'yt_dlp')
        if yt_dlp_path not in sys.path:
            sys.path.insert(0, yt_dlp_path)

        import yt_dlp

        output_dir = '\(outputDir.replacingOccurrences(of: "'", with: "\\'"))'
        url = '\(url.replacingOccurrences(of: "'", with: "\\'"))'
        result_file = '\(resultFilePath.replacingOccurrences(of: "'", with: "\\'"))'

        os.makedirs(output_dir, exist_ok=True)

        ydl_opts = {
            'format': 'bestaudio[ext=m4a]/bestaudio/best',
            'outtmpl': os.path.join(output_dir, '%(title)s.%(ext)s'),
            'quiet': True,
            'no_warnings': True,
            'extract_flat': False,
        }

        result = {}

        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(url, download=True)
                title = info.get('title', 'Unknown')
                video_id = info.get('id', '')
                
                # Find downloaded file
                for f in os.listdir(output_dir):
                    full_path = os.path.join(output_dir, f)
                    if os.path.isfile(full_path):
                        # Check if this is our file
                        if video_id in f or title[:15] in f:
                            result = {
                                'success': True,
                                'title': title,
                                'filepath': full_path
                            }
                            break

            if not result:
                result = {'success': False, 'error': 'File not found after download'}
        except Exception as e:
            result = {'success': False, 'error': str(e)}

        # Write result to file for Swift to read
        with open(result_file, 'w') as f:
            json.dump(result, f)
        """
        
        guard executePython(script) != nil else {
            throw PythonError.executionError("Failed to execute Python")
        }
        
        // Read the result from file
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: resultFilePath)),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw PythonError.executionError("Failed to read yt-dlp result")
        }
        
        // Clean up result file
        try? FileManager.default.removeItem(atPath: resultFilePath)
        
        guard let success = json["success"] as? Bool, success,
              let filepath = json["filepath"] as? String,
              let title = json["title"] as? String else {
            let errorMsg = json["error"] as? String ?? "Unknown error"
            throw PythonError.executionError(errorMsg)
        }
        
        updateStatus("Download complete!")
        return (URL(fileURLWithPath: filepath), title)
    }
    
    private func updateStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
        }
    }
    
    // MARK: - Python C API Bridge
    // These functions call into Python's C API via the xcframework
    
    // Python framework is now configured
    private let pythonFrameworkAvailable = true
    
    private func initializePythonRuntime() -> Bool {
        // Safety check - don't try to call Python if framework isn't linked
        guard pythonFrameworkAvailable else {
            print("ℹ️ [EmbeddedPython] Python framework not configured")
            print("ℹ️ [EmbeddedPython] Using WebView fallback method")
            print("ℹ️ [EmbeddedPython] To enable yt-dlp, follow docs/PYTHON_IOS_SETUP.md")
            return false
        }
        
        // BeeWare's Python-Apple-support requires special initialization
        // We need to skip the import of site and _apple_support initially
        // by setting certain flags
        
        // Skip importing site module (which tries to import _apple_support)
        _Py_NoSiteFlag = 1
        
        // Initialize Python
        _Py_Initialize()
        let initialized = _Py_IsInitialized()
        
        if initialized != 0 {
            print("✅ [EmbeddedPython] Python runtime initialized")
            
            // Now manually set up sys.path by running Python code
            let setupScript = """
            import sys
            # Paths should already be set via PYTHONPATH environment variable
            print(f"Python {sys.version}")
            print(f"sys.path = {sys.path}")
            """
            _ = executePython(setupScript)
            
            return true
        } else {
            print("⚠️ [EmbeddedPython] Python.xcframework not linked or initialization failed")
            print("⚠️ Follow setup instructions in docs/PYTHON_IOS_SETUP.md")
            return false
        }
    }
    
    private func executePython(_ code: String) -> String? {
        // Simpler approach - just run the code directly without output capture
        // The yt-dlp script writes its result with a marker we can find
        
        let result = code.withCString { codePtr in
            _PyRun_SimpleString(codePtr)
        }
        
        if result == 0 {
            print("✅ [EmbeddedPython] Python script executed successfully")
            return "SUCCESS"
        } else {
            print("❌ [EmbeddedPython] Script execution failed with code: \(result)")
            return nil
        }
    }
    
    enum PythonError: Error, LocalizedError {
        case notInitialized
        case executionError(String)
        case downloadFailed
        
        var errorDescription: String? {
            switch self {
            case .notInitialized:
                return "Python interpreter not initialized. See setup instructions."
            case .executionError(let message):
                return "Python error: \(message)"
            case .downloadFailed:
                return "Download failed"
            }
        }
    }
}

// MARK: - Python C API Function Declarations
// These map Swift functions to Python's C API symbols
// They become available when Python.xcframework is linked and bridging header is set

// Py_NoSiteFlag - Skip importing site module (set to 1 before Py_Initialize)
@_silgen_name("Py_NoSiteFlag")
private var _Py_NoSiteFlag: Int32

// Py_Initialize - Initialize the Python interpreter
@_silgen_name("Py_Initialize")
private func _Py_Initialize()

// Py_IsInitialized - Check if Python is initialized (returns 1 if true, 0 if false)
@_silgen_name("Py_IsInitialized")
private func _Py_IsInitialized() -> Int32

// PyRun_SimpleString - Run a Python script string (returns 0 on success, -1 on error)
@_silgen_name("PyRun_SimpleString")
private func _PyRun_SimpleString(_ code: UnsafePointer<CChar>) -> Int32

// Py_Finalize - Shutdown the Python interpreter
@_silgen_name("Py_Finalize")
private func _Py_Finalize()
