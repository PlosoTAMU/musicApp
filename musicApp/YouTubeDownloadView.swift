import SwiftUI

struct YouTubeDownloadView: View {
    @ObservedObject var downloadManager: DownloadManager
    @State private var youtubeURL = ""
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var consoleOutput: String = ""
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Download from YouTube")
                    .font(.headline)
                
                TextField("Paste YouTube URL", text: $youtubeURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(.horizontal)
                
                if isDownloading {
                    VStack(spacing: 12) {
                        ProgressView("Downloading...")
                        
                        // Console output
                        ScrollView {
                            Text(consoleOutput)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 200)
                        .background(Color.black)
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }
                }
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }
                
                Button {
                    startDownload()
                } label: {
                    Text("Download Audio")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(youtubeURL.isEmpty || isDownloading ? Color.gray : Color.blue)
                        .cornerRadius(10)
                }
                .disabled(youtubeURL.isEmpty || isDownloading)
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("YouTube Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func startDownload() {
        isDownloading = true
        errorMessage = nil
        consoleOutput = ""
        
        // Start monitoring log file
        let logPath = NSTemporaryDirectory() + "ytdlp_debug.log"
        
        // Clear old log
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        
        // Poll log file for updates
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if let logContent = try? String(contentsOfFile: logPath, encoding: .utf8) {
                consoleOutput = logContent
            }
        }
        
        Task {
            do {
                let (fileURL, title) = try await EmbeddedPython.shared.downloadAudio(url: youtubeURL)
                
                timer.invalidate()
                
                let thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: fileURL)
                
                let download = Download(
                    name: title,
                    url: fileURL,
                    thumbnailPath: thumbnailPath?.path
                )
                
                await MainActor.run {
                    downloadManager.addDownload(download)
                    youtubeURL = ""
                    isDownloading = false
                }
                
            } catch {
                timer.invalidate()
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDownloading = false
                }
            }
        }
    }
}