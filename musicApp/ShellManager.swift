import Foundation
import PythonKit

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
        
        print("📍 [Shell] Bundle path: \(bundlePath)")
        print("📍 [Shell] Site packages path: \(sitePackagesPath)")
        
        // Python.xcframework is automatically linked, no need to set PYTHONHOME
        // Just set PYTHONPATH to include site-packages
        setenv("PYTHONPATH", sitePackagesPath, 1)
        
        print("📍 [Shell] PYTHONPATH: \(sitePackagesPath)")
        
        do {
            // Initialize Python (uses the linked Python.xcframework)
            Py_Initialize()
            
            // Import sys and add site-packages to path
            let sys = Python.import("sys")
            sys.path.append(sitePackagesPath)
            
            print("✅ [Shell] Python initialized")
            print("📍 [Shell] Python version: \(sys.version)")
            print("📍 [Shell] Python path: \(sys.path)")
            
            pythonInitialized = true
            
            // Verify yt-dlp is available
            verifyYTDLP()
            
        } catch {
            print("❌ [Shell] Failed to initialize Python: \(error)")
        }
    }
    
    private func verifyYTDLP() {
        print("📦 [Shell] Verifying yt-dlp installation...")
        
        do {
            let yt_dlp = Python.import("yt_dlp")
            print("✅ [Shell] yt-dlp found and imported successfully")
            print("📍 [Shell] yt-dlp version: \(yt_dlp.version.__version__)")
            
            DispatchQueue.main.async {
                self.isReady = true
                print("✅ [Shell] Shell environment ready")
            }
        } catch {
            print("❌ [Shell] yt-dlp not found: \(error)")
            print("⚠️ [Shell] Make sure yt-dlp is in python-group/site-packages/")
            
            DispatchQueue.main.async {
                self.isReady = false
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
                // Import yt-dlp
                let yt_dlp = Python.import("yt_dlp")
                
                print("✅ [Shell] yt-dlp imported")
                
                // Configure options
                let ydl_opts = [
                    "format": "bestaudio/best",
                    "quiet": true,
                    "no_warnings": true
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
                let ydl_opts: [String: PythonObject] = [
                    "format": "bestaudio/best",
                    "outtmpl": PythonObject(outputPath),
                    "postprocessors": [
                        [
                            "key": "FFmpegExtractAudio",
                            "preferredcodec": "mp3",
                            "preferredquality": "192"
                        ]
                    ],
                    "quiet": false,
                    "no_warnings": false
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