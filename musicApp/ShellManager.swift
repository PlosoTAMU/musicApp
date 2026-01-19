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
        print("=" * 60)
        
        // Get paths
        guard let bundlePath = Bundle.main.resourcePath else {
            print("❌ [Shell] Could not find bundle path")
            return
        }
        
        print("📍 [Shell] Bundle path: \(bundlePath)")
        print("")
        
        // List what's actually in the bundle
        print("📦 [Shell] Contents of bundle:")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: bundlePath) {
            for item in contents.sorted() {
                let isDir = (try? FileManager.default.attributesOfItem(atPath: "\(bundlePath)/\(item)"))?[.type] as? FileAttributeType == .typeDirectory
                print("   \(isDir == true ? "📁" : "📄") \(item)")
            }
        }
        print("")
        
        // Check Frameworks directory
        let frameworksPath = "\(bundlePath)/Frameworks"
        print("📦 [Shell] Checking Frameworks directory: \(frameworksPath)")
        if FileManager.default.fileExists(atPath: frameworksPath) {
            if let frameworks = try? FileManager.default.contentsOfDirectory(atPath: frameworksPath) {
                for framework in frameworks.sorted() {
                    print("   📦 \(framework)")
                    
                    // If it's Python.framework, show its contents
                    if framework.contains("Python") {
                        let pythonPath = "\(frameworksPath)/\(framework)"
                        print("      Contents of \(framework):")
                        if let pythonContents = try? FileManager.default.contentsOfDirectory(atPath: pythonPath) {
                            for item in pythonContents.sorted() {
                                print("         - \(item)")
                                
                                // Show deeper structure for important directories
                                let fullPath = "\(pythonPath)/\(item)"
                                var isDir: ObjCBool = false
                                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                                    if let subContents = try? FileManager.default.contentsOfDirectory(atPath: fullPath) {
                                        for subItem in subContents.prefix(10) {
                                            print("            • \(subItem)")
                                        }
                                        if subContents.count > 10 {
                                            print("            • ... and \(subContents.count - 10) more items")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            print("   ❌ Frameworks directory doesn't exist!")
        }
        print("")
        
        // Path to python-group with site-packages (where yt-dlp is)
        let pythonGroupPath = "\(bundlePath)/python-group"
        print("📦 [Shell] Checking python-group: \(pythonGroupPath)")
        if FileManager.default.fileExists(atPath: pythonGroupPath) {
            print("   ✅ python-group exists")
            let sitePackagesPath = "\(pythonGroupPath)/site-packages"
            if FileManager.default.fileExists(atPath: sitePackagesPath) {
                print("   ✅ site-packages exists")
                if let packages = try? FileManager.default.contentsOfDirectory(atPath: sitePackagesPath) {
                    print("   Packages found:")
                    for pkg in packages.sorted() {
                        print("      - \(pkg)")
                    }
                }
            } else {
                print("   ❌ site-packages doesn't exist!")
            }
        } else {
            print("   ❌ python-group doesn't exist!")
        }
        print("")
        
        print("=" * 60)
        print("⚠️  [Shell] PLEASE SEND ME THE OUTPUT ABOVE")
        print("    I need to see the actual directory structure")
        print("    to tell you exactly where to put the Python stdlib")
        print("=" * 60)
        
        // For now, don't initialize Python
        return
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