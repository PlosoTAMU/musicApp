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
        let pythonHome = resourcePath.appending("/python-stdlib")
        let pythonPath = [
            pythonHome,
            pythonHome + "/lib-dynload",
            resourcePath + "/yt_dlp",
        ].joined(separator: ":")
        
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

        os.makedirs(output_dir, exist_ok=True)

        ydl_opts = {
            'format': 'bestaudio[ext=m4a]/bestaudio/best',
            'outtmpl': os.path.join(output_dir, '%(title)s.%(ext)s'),
            'quiet': True,
            'no_warnings': True,
            'extract_flat': False,
        }

        result = {}

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

        print('YTDLP_RESULT:' + json.dumps(result))
        """
        
        guard let output = executePython(script) else {
            throw PythonError.executionError("Failed to execute Python")
        }
        
        // Parse the result
        guard let resultStart = output.range(of: "YTDLP_RESULT:") else {
            throw PythonError.downloadFailed
        }
        
        let jsonString = String(output[resultStart.upperBound..<output.endIndex])
        
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let success = json["success"] as? Bool, success,
              let filepath = json["filepath"] as? String,
              let title = json["title"] as? String else {
            
            // Try to extract error message
            if let errorRange = output.range(of: "error") {
                let errorMsg = String(output[errorRange.lowerBound..<output.endIndex])
                throw PythonError.executionError(errorMsg)
            }
            throw PythonError.downloadFailed
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
    // The bridging header (Python-Bridging-Header.h) imports Python.h
    
    private func initializePythonRuntime() -> Bool {
        // Check if Python functions are available (via bridging header)
        // The @_silgen_name declarations below map to Python C API functions
        
        _Py_Initialize()
        let initialized = _Py_IsInitialized()
        
        if initialized != 0 {
            print("✅ [EmbeddedPython] Python runtime initialized")
            return true
        } else {
            print("⚠️ [EmbeddedPython] Python.xcframework not linked or initialization failed")
            print("⚠️ Follow setup instructions in docs/PYTHON_IOS_SETUP.md")
            return false
        }
    }
    
    private func executePython(_ code: String) -> String? {
        // Create a pipe to capture stdout
        let stdoutPipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        
        // Run the Python code
        let result = code.withCString { codePtr in
            _PyRun_SimpleString(codePtr)
        }
        
        // Restore stdout and read captured output
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        stdoutPipe.fileHandleForWriting.closeFile()
        
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)
        
        if result == 0 {
            return output
        } else {
            print("❌ [EmbeddedPython] Script execution failed")
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
