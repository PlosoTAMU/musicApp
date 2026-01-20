import Foundation
import ffmpegkit

/// Manages an embedded Python interpreter for running yt-dlp on iOS
class EmbeddedPython: ObservableObject {
    static let shared = EmbeddedPython()
    
    @Published var isInitialized = false
    @Published var statusMessage = ""
    @Published var downloadProgress: Double = 0.0
    
    private var pythonInitialized = false
    private let pythonQueue = DispatchQueue(label: "com.musicapp.python", qos: .userInitiated)
    
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
        var pythonVersion = "python3.14"
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
    
    func downloadAudio(url: String) async throws -> (URL, String) {
        guard pythonInitialized else {
            throw PythonError.notInitialized
        }
        
        updateStatus("Starting download...")
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputDir = documentsPath.appendingPathComponent("YouTube Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        return try await withCheckedThrowingContinuation { continuation in
            pythonQueue.async { [weak self] in
                do {
                    // Python downloads directly with final filename - no conversion needed
                    let result = try self?.runYtdlp(url: url, outputDir: outputDir.path) ?? (URL(fileURLWithPath: ""), "")
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    
    private func runYtdlp(url: String, outputDir: String) throws -> (URL, String) {
        let resultFilePath = NSTemporaryDirectory() + "ytdlp_result.json"
        let logFilePath = NSTemporaryDirectory() + "ytdlp_debug.log"
        
        print("🎬 [runYtdlp] Starting download for URL: \(url)")
        print("🎬 [runYtdlp] Output directory: \(outputDir)")
        
        let script = """
        import sys
        import os
        import json
        
        log_file = r'''\(logFilePath)'''
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
        url = r'''\(url.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: ""))'''
        os.makedirs(output_dir, exist_ok=True)
        
        
        # Generate video-ID-based filename directly
        ydl_opts = {
            'format': '140/bestaudio[ext=m4a]/bestaudio/best',
            'user_agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'quiet': False,
            'noplaylist': True,
            # Save directly with video ID (no temp file)
            'outtmpl': os.path.join(output_dir, '%(id)s.%(ext)s'),
            'extractor_args': {
                'youtube': {
                    'player_client': ['ios', 'android'],
                    'skip': ['web'],
                }
            },
        }
        
        result = {}
        try:
            log('Creating YoutubeDL instance...')
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(url, download=True)
                title = info.get('title', 'Unknown')
                video_id = info.get('id', unique_id)
                downloaded_path = ydl.prepare_filename(info)
                
                log(f'Downloaded: {downloaded_path}')
                
                if os.path.exists(downloaded_path):
                    result = {
                        'success': True,
                        'title': title,
                        'audio_url': downloaded_path,
                        'audio_ext': info.get('ext', 'm4a'),
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
        
        print("🎬 [runYtdlp] Executing Python script...")
        let startTime = Date()
        
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
        
        let audioURL = URL(fileURLWithPath: audioURLString)
        print("✅ [runYtdlp] Downloaded to: \(audioURL.path)")
        return (audioURL, title)
    }
    
    private func updateStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
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

// Python C API
@_silgen_name("Py_NoSiteFlag") private var _Py_NoSiteFlag: Int32
@_silgen_name("Py_Initialize") private func _Py_Initialize()
@_silgen_name("Py_IsInitialized") private func _Py_IsInitialized() -> Int32
@_silgen_name("PyRun_SimpleString") private func _PyRun_SimpleString(_ code: UnsafePointer<CChar>) -> Int32
@_silgen_name("Py_Finalize") private func _Py_Finalize()
@_silgen_name("PyGILState_Ensure") private func _PyGILState_Ensure() -> Int32
@_silgen_name("PyGILState_Release") private func _PyGILState_Release(_ state: Int32)
@_silgen_name("PyEval_SaveThread") private func _PyEval_SaveThread() -> UnsafeMutableRawPointer?