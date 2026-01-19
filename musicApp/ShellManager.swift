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
        
        // Get paths
        guard let bundlePath = Bundle.main.resourcePath else {
            print("❌ [Shell] Could not find bundle path")
            return
        }
        
        // Path to python-group with site-packages (where yt-dlp is)
        let pythonGroupPath = "\(bundlePath)/python-group"
        let sitePackagesPath = "\(pythonGroupPath)/site-packages"
        
        // Look for Python standard library in Python.xcframework
        // It might be in: Python.framework/Versions/3.X/lib/python3.X
        let pythonFrameworkPath = "\(bundlePath)/Frameworks/Python.framework"
        var pythonLibPath = ""
        
        // Try to find the lib directory
        if FileManager.default.fileExists(atPath: "\(pythonFrameworkPath)/lib") {
            pythonLibPath = "\(pythonFrameworkPath)/lib"
        } else if FileManager.default.fileExists(atPath: "\(pythonFrameworkPath)/Versions/Current/lib") {
            pythonLibPath = "\(pythonFrameworkPath)/Versions/Current/lib"
        }
        
        print("📍 [Shell] Bundle path: \(bundlePath)")
        print("📍 [Shell] Python framework path: \(pythonFrameworkPath)")
        print("📍 [Shell] Python lib path: \(pythonLibPath)")
        print("📍 [Shell] Site packages path: \(sitePackagesPath)")
        
        // Set PYTHONHOME to Python framework location
        if !pythonLibPath.isEmpty {
            let pythonHome = (pythonLibPath as NSString).deletingLastPathComponent
            setenv("PYTHONHOME", pythonHome, 1)
            print("📍 [Shell] PYTHONHOME: \(pythonHome)")
        }
        
        // Set PYTHONPATH to include both standard library and site-packages
        var pythonPathComponents: [String] = []
        
        if !pythonLibPath.isEmpty {
            // Add standard library paths
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: pythonLibPath) {
                for item in contents {
                    if item.hasPrefix("python3") {
                        pythonPathComponents.append("\(pythonLibPath)/\(item)")
                        print("📍 [Shell] Found Python lib: \(pythonLibPath)/\(item)")
                    }
                }
            }
        }
        
        // Add site-packages
        pythonPathComponents.append(sitePackagesPath)
        
        let pythonPath = pythonPathComponents.joined(separator: ":")
        setenv("PYTHONPATH", pythonPath, 1)
        print("📍 [Shell] PYTHONPATH: \(pythonPath)")
        
        // Import sys and add paths
        let sys = Python.import("sys")
        for path in pythonPathComponents {
            sys.path.append(path)
        }
        
        print("✅ [Shell] Python initialized")
        print("📍 [Shell] Python version: \(sys.version)")
        print("📍 [Shell] Python path: \(sys.path)")
        
        pythonInitialized = true
        
        // Verify yt-dlp is available
        verifyYTDLP()
    }
    
    private func verifyYTDLP() {
        print("📦 [Shell] Verifying yt-dlp installation...")
        
        let yt_dlp = Python.import("yt_dlp")
        print("✅ [Shell] yt-dlp found and imported successfully")
        
        // Try to get version
        if let version = yt_dlp.checking.version {
            print("📍 [Shell] yt-dlp version: \(version)")
        }
        
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
                // Import yt-dlp
                let yt_dlp = Python.import("yt_dlp")
                
                print("✅ [Shell] yt-dlp imported")
                
                // Configure options as PythonObject
                let ydl_opts: PythonObject = [
                    "format": PythonObject("bestaudio/best"),
                    "quiet": PythonObject(true),
                    "no_warnings": PythonObject(true)
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
                    "quiet": PythonObject(false),
                    "no_warnings": PythonObject(false)
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