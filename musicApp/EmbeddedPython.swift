
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
    
    // CRITICAL: All Python operations MUST run on this single dedicated queue
    // Python is not thread-safe and the GIL must be acquired from the same thread
    private let pythonQueue = DispatchQueue(label: "com.musicapp.python", qos: .userInitiated)
    
    init() {
        // Python will be initialized on first use
    }
    
    /// Initialize Python interpreter - call at app launch
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
            resourcePath,                      // Add bundle root so 'import yt_dlp' works (it's in the root)
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
        setenv("PYTHONIOENCODING", "utf-8", 1)
        
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
            // CRITICAL: Run on the same queue where Python was initialized
            pythonQueue.async { [weak self] in
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
        let logFilePath = NSTemporaryDirectory() + "ytdlp_debug.log"
        
        print("🎬 [runYtdlp] Starting download for URL: \(url)")
        print("🎬 [runYtdlp] Output directory: \(outputDir)")
        print("🎬 [runYtdlp] Result file: \(resultFilePath)")
        
        let script = """
        import sys
        import os
        import json
        import uuid
        log_file = r'''\(logFilePath)'''
        def log(msg):
            try:
                with open(log_file, 'a', encoding='utf-8') as f:
                    f.write(str(msg) + '\\n')
            except:
                pass
            try:
                print(msg)
            except:
                try:
                    print(str(msg).encode('utf-8', errors='replace').decode('utf-8'))
                except:
                    pass
        log('=== yt-dlp Debug Log ===')
        log(f'Python version: {sys.version}')
        log(f'sys.path: {sys.path}')
        log(f'CWD: {os.getcwd()}')
        log('Attempting to import yt_dlp...')
        try:
            import yt_dlp
            log(f'yt_dlp imported successfully, version: {getattr(yt_dlp, "version", "unknown")}')
        except Exception as e:
            log(f'Failed to import yt_dlp: {e}')
            result = {'success': False, 'error': f'Failed to import yt_dlp: {e}'}
            result_file = r'''\(resultFilePath)'''
            with open(result_file, 'w', encoding='utf-8') as f:
                json.dump(result, f)
            raise
        output_dir = r'''\(outputDir)'''
        url = r'''\(url.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: ""))'''
        result_file = r'''\(resultFilePath)'''
        log(f'Output dir: {output_dir}')
        log(f'URL: {url}')
        os.makedirs(output_dir, exist_ok=True)
        log('Output directory created/verified')

        # Generate unique ID for this download
        unique_id = str(uuid.uuid4())[:8]
        temp_filename = f'temp_{unique_id}'
        
        ydl_opts = {
            # CRITICAL: Force audio-only format to avoid SABR issues
            # Format 140 is m4a audio-only (works reliably)
            'format': '140/bestaudio[ext=m4a]/bestaudio/best',
            'user_agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'quiet': False,
            'verbose': False,
            'noplaylist': True,
            # Save with unique temp name
            'outtmpl': os.path.join(output_dir, f'{temp_filename}.%(ext)s'),
            'extractor_args': {
                'youtube': {
                    'player_client': ['ios', 'android'],
                    'skip': ['web'],
                }
            },
        }

        log(f'ydl_opts: {ydl_opts}')
        log(f'Unique ID for this download: {unique_id}')
        result = {}
        try:
            log('Creating YoutubeDL instance...')
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                log('YoutubeDL instance created, extracting info...')
                info = ydl.extract_info(url, download=True)
                log(f'Info extracted, title: {info.get("title", "Unknown")}')
                title = info.get('title', 'Unknown')
                video_id = info.get('id', unique_id)
                log(f'Video ID: {video_id}')
                log(f'Looking for downloaded file in {output_dir}...')
                downloaded_path = ydl.prepare_filename(info)
                log(f'Downloaded file: {downloaded_path}')
                
                if not os.path.exists(downloaded_path):
                    log(f'ERROR: Downloaded file not found at expected path')
                    result = {'success': False, 'error': 'Downloaded file not found'}
                else:
                    log(f'File found, size: {os.path.getsize(downloaded_path)} bytes')
                    
                    # Now convert to m4a (most compressed audio format)
                    final_filename = f'{video_id}.m4a'
                    final_path = os.path.join(output_dir, final_filename)
                    
                    log(f'Converting to m4a: {final_path}')
                    
                    # Now convert to AAC (iOS-compatible, highly compressed)
                    final_filename = f'{video_id}.m4a'
                    final_path = os.path.join(output_dir, final_filename)

                    log(f'Converting to AAC: {final_path}')

                    try:
                        import ffmpegkit
                        log('ffmpegkit imported')
                        
                        # Build FFmpeg command for AAC conversion at 64kbps
                        ffmpeg_command = f'-i "{downloaded_path}" -vn -acodec aac -b:a 64k -y "{final_path}"'
                        log(f'FFmpeg command: {ffmpeg_command}')
                        
                        # Execute FFmpeg command
                        session = ffmpegkit.FFmpegKit.execute(ffmpeg_command)
                        return_code = session.getReturnCode()
                        
                        log(f'FFmpeg return code: {return_code}')
                        
                        if return_code.isValueSuccess():
                            if os.path.exists(final_path):
                                log(f'Conversion successful: {final_path}')
                                log(f'Final size: {os.path.getsize(final_path)} bytes')
                                
                                # Delete temp file
                                try:
                                    os.remove(downloaded_path)
                                    log(f'Removed temp file: {downloaded_path}')
                                except Exception as e:
                                    log(f'Failed to remove temp file: {e}')
                                
                                result = {
                                    'success': True,
                                    'title': title,
                                    'audio_url': final_path,
                                    'audio_ext': 'm4a',
                                }
                            else:
                                log(f'ERROR: Conversion completed but output file not found')
                                result = {'success': False, 'error': 'FFmpeg output file missing'}
                        else:
                            # Get error output
                            error_output = session.getFailStackTrace()
                            log(f'ERROR: FFmpeg conversion failed')
                            log(f'Error output: {error_output}')
                            result = {'success': False, 'error': f'FFmpeg failed with code {return_code}'}
                            
                    except ImportError as e:
                        log(f'ERROR: ffmpegkit not available: {e}')
                        log('Falling back to original file without conversion')
                        # Rename temp file to use video ID
                        fallback_path = os.path.join(output_dir, f'{video_id}.{info.get("ext", "m4a")}')
                        try:
                            os.rename(downloaded_path, fallback_path)
                            log(f'Renamed to: {fallback_path}')
                            result = {
                                'success': True,
                                'title': title,
                                'audio_url': fallback_path,
                                'audio_ext': info.get('ext', 'm4a'),
                            }
                        except Exception as e:
                            log(f'ERROR: Failed to rename: {e}')
                            result = {'success': False, 'error': f'Rename failed: {e}'}
                            
                    except Exception as e:
                        log(f'ERROR: FFmpeg conversion failed: {e}')
                        import traceback
                        log(traceback.format_exc())
                        # Fall back to original file
                        fallback_path = os.path.join(output_dir, f'{video_id}.{info.get("ext", "m4a")}')
                        try:
                            os.rename(downloaded_path, fallback_path)
                            log(f'Fallback: renamed to {fallback_path}')
                            result = {
                                'success': True,
                                'title': title,
                                'audio_url': fallback_path,
                                'audio_ext': info.get('ext', 'm4a'),
                            }
                        except Exception as e:
                            log(f'ERROR: Fallback rename failed: {e}')
                            result = {'success': False, 'error': f'Conversion and fallback failed: {e}'}
                    
        except Exception as e:
            log(f'Exception during download: {type(e).__name__}: {e}')
            import traceback
            log(traceback.format_exc())
            result = {'success': False, 'error': str(e)}
        
        log(f'Final result: {result}')
        # Write result to file for Swift to read
        with open(result_file, 'w', encoding='utf-8') as f:
            json.dump(result, f)
        log('Result written to file')
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
        print("🎬 [runYtdlp] Python script completed in \(elapsed) seconds")
        
        if let debugLog = try? String(contentsOfFile: logFilePath, encoding: .utf8) {
            print("📋 [runYtdlp] Debug log:\n\(debugLog)")
        }
        try? FileManager.default.removeItem(atPath: logFilePath)
        
        print("🎬 [runYtdlp] Reading result file...")
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: resultFilePath)),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("❌ [runYtdlp] Failed to read result file at: \(resultFilePath)")
            throw PythonError.executionError("Failed to read yt-dlp result")
        }
        
        print("🎬 [runYtdlp] Result JSON: \(json)")
        try? FileManager.default.removeItem(atPath: resultFilePath)
        
        guard let success = json["success"] as? Bool, success,
            let audioURLString = json["audio_url"] as? String,
            let title = json["title"] as? String else {
            let errorMsg = json["error"] as? String ?? "Unknown error"
            print("❌ [runYtdlp] Download failed: \(errorMsg)")
            throw PythonError.executionError(errorMsg)
        }

        let audioURL = URL(fileURLWithPath: audioURLString)
        print("✅ [runYtdlp] Audio saved to: \(audioURL.path)")
        return (audioURL, title)
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
        // Skip importing site module (which tries to import _apple_support)
        _Py_NoSiteFlag = 1
        
        // Initialize Python
        _Py_Initialize()
        let initialized = _Py_IsInitialized()
        
        if initialized != 0 {
            // Release the GIL immediately after initialization so that
            // subsequent calls using PyGILState_Ensure work correctly.
            _ = _PyEval_SaveThread()
            print("✅ [EmbeddedPython] Python runtime initialized (GIL released)")
            return true
        } else {
            print("⚠️ [EmbeddedPython] Python.xcframework not linked or initialization failed")
            print("⚠️ Follow setup instructions in docs/PYTHON_IOS_SETUP.md")
            return false
        }
    }
    
    private func executePython(_ code: String) -> String? {
        print("🐍 [executePython] Starting...")
        print("🐍 [executePython] Thread: \(Thread.current)")
        
        // CRITICAL: Must check Python is initialized
        let isInit = _Py_IsInitialized()
        print("🐍 [executePython] Python initialized: \(isInit)")
        
        guard isInit != 0 else {
            print("❌ [EmbeddedPython] Python not initialized when trying to execute")
            return nil
        }
        
        // Ensure we hold the GIL before executing Python code
        let gstate = _PyGILState_Ensure()
        defer {
            _PyGILState_Release(gstate)
        }
        
        // Use withCString to ensure pointer validity during the call
        let result = code.withCString { ptr -> Int32 in
            print("🐍 [executePython] Running PyRun_SimpleString...")
            return _PyRun_SimpleString(ptr)
        }
        
        print("🐍 [executePython] PyRun_SimpleString returned: \(result)")
        
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

// PyGILState_Ensure - Acquire the Global Interpreter Lock (for thread safety)
@_silgen_name("PyGILState_Ensure")
private func _PyGILState_Ensure() -> Int32

// PyGILState_Release - Release the Global Interpreter Lock
@_silgen_name("PyGILState_Release")
private func _PyGILState_Release(_ state: Int32)

// PyEval_SaveThread - Release the GIL and return thread state
@_silgen_name("PyEval_SaveThread")
private func _PyEval_SaveThread() -> UnsafeMutableRawPointer?

