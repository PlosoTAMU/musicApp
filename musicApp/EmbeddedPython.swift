import Foundation
import ffmpegkit

final class EmbeddedPython: ObservableObject {
    static let shared = EmbeddedPython()

    @Published var isInitialized = false
    @Published var statusMessage = ""

    private var pythonInitialized = false
    private let pythonQueue = DispatchQueue(label: "com.musicapp.python", qos: .userInitiated)

    private init() {}

    func initialize() {
        guard !pythonInitialized else { return }
        pythonQueue.async { [weak self] in self?.setupPython() }
    }

    func downloadAudio(url: String) async throws -> (URL, String) {
        guard pythonInitialized else { throw PythonError.notInitialized }
        updateStatus("Starting download...")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outDir = docs.appendingPathComponent("YouTube Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        return try await withCheckedThrowingContinuation { cont in
            pythonQueue.async { [weak self] in
                guard let self = self else { return cont.resume(throwing: PythonError.executionError("self deallocated")) }
                do {
                    let (file, title) = try self.runYtdlp(url: url, outputDir: outDir.path)
                    var final = file
                    if final.pathExtension.lowercased() != "m4a" {
                        self.updateStatus("Converting to m4a...")
                        final = try self.convertToM4A(inputURL: final, title: title)
                    }
                    cont.resume(returning: (final, title))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func runYtdlp(url: String, outputDir: String) throws -> (URL, String) {
        let resultFile = NSTemporaryDirectory() + "ytdlp_result.json"
        let logFile = NSTemporaryDirectory() + "ytdlp_debug.log"

        let script = """
import sys, os, json
log_file = r'''\(logFile)'''
def log(m):
    try:
        with open(log_file, 'a', encoding='utf-8') as f:
            f.write(str(m) + '\n')
    except:
        pass

try:
    import yt_dlp
except Exception as e:
    with open(r'''\(resultFile)''', 'w', encoding='utf-8') as f:
        json.dump({'success': False, 'error': str(e)}, f)
    raise

output_dir = r'''\(outputDir)'''
os.makedirs(output_dir, exist_ok=True)
ydl_opts = {
    'format': 'bestaudio[ext=m4a]/bestaudio/best',
    'http_headers': {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://www.youtube.com/'},
    'extractor_args': {'youtube': {'player_client': ['android','web','tv_html5']}},
    'allow_unplayable_formats': True,
    'ignore_no_formats_error': True,
    'noplaylist': True,
    'quiet': True,
    'outtmpl': os.path.join(output_dir, '%(title)s.%(ext)s')
}

try:
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(r'''\(url)''', download=True)
        p = ydl.prepare_filename(info)
        t = info.get('title','Unknown')
        e = info.get('ext','')
    with open(r'''\(resultFile)''', 'w', encoding='utf-8') as f:
        json.dump({'success': True, 'title': t, 'audio_url': p, 'audio_ext': e}, f)
except Exception as e:
    with open(r'''\(resultFile)''', 'w', encoding='utf-8') as f:
        json.dump({'success': False, 'error': str(e)}, f)
    raise
"""

        guard executePython(script) != nil else {
            if let dbg = try? String(contentsOfFile: logFile, encoding: .utf8) { print(dbg) }
            throw PythonError.executionError("executePython failed")
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resultFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String:Any] else {
            throw PythonError.executionError("no result")
        }
        try? FileManager.default.removeItem(atPath: resultFile)

        if let ok = json["success"] as? Bool, ok,
           let path = json["audio_url"] as? String,
           let title = json["title"] as? String {
            return (URL(fileURLWithPath: path), title)
        } else {
            let err = json["error"] as? String ?? "unknown"
            throw PythonError.executionError(err)
        }
    }

    private func convertToM4A(inputURL: URL, title: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = title.replacingOccurrences(of: "[\\/:*?\"<>|]", with: "-", options: .regularExpression)
        let out = docs.appendingPathComponent("\(safe).m4a")
        if FileManager.default.fileExists(atPath: out.path) { try? FileManager.default.removeItem(at: out) }
        let cmd = "-i \"\(inputURL.path)\" -vn -c:a aac -b:a 192k \"\(out.path)\""
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var convErr: Error?
        ffmpegkit.executeAsync(cmd) { session in
            if ReturnCode.isSuccess(session?.getReturnCode()) { ok = true } else { convErr = PythonError.executionError("ffmpeg failed") }
            sem.signal()
        }
        _ = sem.wait(timeout: .distantFuture)
        if ok { return out } else { throw convErr ?? PythonError.executionError("ffmpeg failed") }
    }

    private func updateStatus(_ m: String) { DispatchQueue.main.async { self.statusMessage = m } }

    // --- Python bridge ---
    private func setupPython() {
        guard let resourcePath = Bundle.main.resourcePath else { updateStatus("no resources"); return }
        let pythonHome = resourcePath + "/python-stdlib"
        let libPath = pythonHome + "/lib"
        let pythonPath = [libPath, pythonHome, resourcePath].joined(separator: ":")
        setenv("PYTHONHOME", pythonHome, 1)
        setenv("PYTHONPATH", pythonPath, 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUNBUFFERED", "1", 1)
        setenv("PYTHONIOENCODING", "utf-8", 1)
        if initializePythonRuntime() { pythonInitialized = true; DispatchQueue.main.async { self.isInitialized = true } }
    }

    private func initializePythonRuntime() -> Bool {
        _Py_NoSiteFlag = 1
        _Py_Initialize()
        let ok = _Py_IsInitialized()
        if ok != 0 { _ = _PyEval_SaveThread(); return true } else { return false }
    }

    private func executePython(_ code: String) -> String? {
        guard _Py_IsInitialized() != 0 else { return nil }
        let g = _PyGILState_Ensure(); defer { _PyGILState_Release(g) }
        let r = code.withCString { _PyRun_SimpleString($0) }
        return r == 0 ? "OK" : nil
    }

    enum PythonError: Error, LocalizedError {
        case notInitialized
        case executionError(String)
        var errorDescription: String? { switch self { case .notInitialized: return "Python not initialized"; case .executionError(let m): return m } }
    }
}

// C API
@_silgen_name("Py_NoSiteFlag") private var _Py_NoSiteFlag: Int32
@_silgen_name("Py_Initialize") private func _Py_Initialize()
@_silgen_name("Py_IsInitialized") private func _Py_IsInitialized() -> Int32
@_silgen_name("PyRun_SimpleString") private func _PyRun_SimpleString(_ code: UnsafePointer<CChar>) -> Int32
@_silgen_name("PyGILState_Ensure") private func _PyGILState_Ensure() -> Int32
@_silgen_name("PyGILState_Release") private func _PyGILState_Release(_ state: Int32)
@_silgen_name("PyEval_SaveThread") private func _PyEval_SaveThread() -> UnsafeMutableRawPointer?