import Foundation
import PythonKit

// Video info structure for YouTube extraction
struct VideoInfo {
    let title: String
    let author: String
    let duration: Int
    let audioURL: URL
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
        
        // Initialize Python via PythonKit
        let sys = Python.import("sys")
        sys.path.insert(0, pythonStdlibPath)
        sys.path.append(sitePackagesPath)
        
        print("✅ [Shell] Python initialized")
        print("📍 [Shell] Python version: \(sys.version)")
        print("📍 [Shell] sys.path: \(sys.path)")
        
        pythonInitialized = true
        
        // Verify yt-dlp is available
        verifyYTDLP()
    }
    
    private func verifyYTDLP() {
        print("📦 [Shell] Verifying yt-dlp installation...")
        
        do {
            // Suppress warnings about Apple-specific modules
            let warnings = Python.import("warnings")
            warnings.filterwarnings("ignore")
            
            let yt_dlp = Python.import("yt_dlp")
            print("✅ [Shell] yt-dlp found and imported successfully")
            
            DispatchQueue.main.async {
                self.isReady = true
                print("✅ [Shell] Shell environment ready")
            }
        } catch {
            print("⚠️  [Shell] Warning during yt-dlp verification: \(error)")
            // Still mark as ready - we'll handle errors during actual use
            DispatchQueue.main.async {
                self.isReady = true
            }
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
                // Suppress Apple-specific warnings
                let warnings = Python.import("warnings")
                warnings.filterwarnings("ignore")
                
                // Disable yt-dlp logger to avoid Apple log stream issues
                let logging = Python.import("logging")
                logging.disable(logging.CRITICAL)
                
                // Import yt-dlp
                let yt_dlp = Python.import("yt_dlp")
                
                print("✅ [Shell] yt-dlp imported")
                
                // Configure options as PythonObject - disable all logging
                let ydl_opts: PythonObject = [
                    "format": PythonObject("bestaudio/best"),
                    "quiet": PythonObject(true),
                    "no_warnings": PythonObject(true),
                    "logger": PythonObject(Python.None)
                ]
                
                // Create instance and extract info
                let ydl = yt_dlp.YoutubeDL(ydl_opts)
                let info = ydl.extract_info(url, download: false)
                
                // Parse results
                let title = String(info["title"]) ?? "Unknown"
                let author = String(info["uploader"]) ?? "Unknown"
                let duration = Int(info["duration"]) ?? 0
                let urlString = String(info["url"]) ?? ""
                
                print("✅ [Shell] Extraction complete")
                print("📝 Title: \(title)")
                
                guard let audioURL = URL(string: urlString) else {
                    completion(.failure(ShellError.invalidURL))
                    return
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
                // Suppress Apple-specific warnings
                let warnings = Python.import("warnings")
                warnings.filterwarnings("ignore")
                
                // Disable yt-dlp logger to avoid Apple log stream issues
                let logging = Python.import("logging")
                logging.disable(logging.CRITICAL)
                
                // Import yt-dlp
                let yt_dlp = Python.import("yt_dlp")
                
                // Configure options for direct download
                let postprocessors: PythonObject = [[
                    "key": PythonObject("FFmpegExtractAudio"),
                    "preferredcodec": PythonObject("mp3"),
                    "preferredquality": PythonObject("192")
                ]]
                
                let ydl_opts: PythonObject = [
                    "format": PythonObject("bestaudio/best"),
                    "outtmpl": PythonObject(outputPath),
                    "postprocessors": postprocessors,
                    "quiet": PythonObject(true),
                    "no_warnings": PythonObject(true),
                    "logger": PythonObject(Python.None)
                ]
                
                // Create instance and download
                let ydl = yt_dlp.YoutubeDL(ydl_opts)
                let info = ydl.extract_info(url, download: true)
                
                let title = String(info["title"]) ?? "Unknown"
                
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
