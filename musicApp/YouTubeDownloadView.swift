import SwiftUI
import CryptoKit

struct YouTubeDownloadView: View {
    @ObservedObject var downloadManager: DownloadManager
    @StateObject private var embeddedPython = EmbeddedPython.shared
    @State private var youtubeURL = ""
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var consoleOutput: String = ""
    @State private var showRenameAlert = false
    @State private var downloadedFileURL: URL?
    @State private var downloadedTitle: String = ""
    @State private var newTitle: String = ""
    @FocusState private var isRenameFocused: Bool
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Download from YouTube")
                    .font(.headline)
                
                if isDownloading {
                    VStack(spacing: 12) {
                        ProgressView("Downloading...")
                        
                        // Console output with auto-scroll
                        ScrollView {
                            ScrollViewReader { proxy in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(consoleOutput)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.green)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id("bottom")
                                }
                                .onChange(of: consoleOutput) { _ in
                                    withAnimation {
                                        proxy.scrollTo("bottom", anchor: .bottom)
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 250)
                        .background(Color.black)
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }
                } else {
                    Text("Paste a YouTube or Spotify URL")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 20)
                    
                    Spacer()
                }
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }
                
                if !isDownloading {
                    Spacer()
                }
            }
            .padding(.top, 20)
            .navigationTitle("YouTube Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isDownloading)
                }
            }
            .onAppear {
                // Auto-paste from clipboard and start download
                if let clipboardString = UIPasteboard.general.string,
                   !clipboardString.isEmpty,
                   (clipboardString.contains("youtube.com") || 
                    clipboardString.contains("youtu.be") || 
                    clipboardString.contains("spotify.com")) {
                    youtubeURL = clipboardString
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        startDownload()
                    }
                }
            }
            .alert("Rename Song", isPresented: $showRenameAlert) {
                TextField("Song Title", text: $newTitle)
                    .autocapitalization(.words)
                
                Button("Cancel", role: .cancel) {
                    finishDownload(keepOriginalName: true)
                }
                
                Button("Save") {
                    finishDownload(keepOriginalName: false)
                }
            } message: {
                Text("Enter a new title for this song")
            }
        }
    }
    
    private func startDownload() {
        // Extract video ID BEFORE downloading
        guard let videoID = extractVideoID(from: youtubeURL) else {
            errorMessage = "Invalid URL"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                dismiss()
            }
            return
        }
        
        // Check if already downloaded by video ID
        if downloadManager.hasVideoID(videoID) {
            if let existing = downloadManager.downloads.first(where: { $0.videoID == videoID }) {
                errorMessage = "Already downloaded: \(existing.name)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    dismiss()
                }
            }
            return
        }
        
        isDownloading = true
        errorMessage = nil
        consoleOutput = ""
        
        // Start monitoring log file
        let logPath = NSTemporaryDirectory() + "ytdlp_debug.log"
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let logContent = try? String(contentsOfFile: logPath, encoding: .utf8) {
                DispatchQueue.main.async {
                    consoleOutput = logContent
                }
            }
        }
        
        Task {
            do {
                let (fileURL, title) = try await embeddedPython.downloadAudio(url: youtubeURL)
                
                timer.invalidate()
                
                if let finalLog = try? String(contentsOfFile: logPath, encoding: .utf8) {
                    await MainActor.run {
                        consoleOutput = finalLog
                    }
                }
                
                let thumbnailPath = embeddedPython.getThumbnailPath(for: fileURL)
                
                await MainActor.run {
                    downloadedFileURL = fileURL
                    downloadedTitle = title
                    newTitle = title
                    youtubeURL = ""
                    isDownloading = false
                    
                    // Show rename dialog
                    showRenameAlert = true
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
    
    private func finishDownload(keepOriginalName: Bool) {
        guard let fileURL = downloadedFileURL else { return }
        
        let finalTitle = keepOriginalName ? downloadedTitle : newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbnailPath = embeddedPython.getThumbnailPath(for: fileURL)
        let videoID = extractVideoID(from: youtubeURL)
        
        if !keepOriginalName && finalTitle != downloadedTitle {
            updateMetadata(for: fileURL, newTitle: finalTitle)
        }
        
        let download = Download(
            name: finalTitle.isEmpty ? downloadedTitle : finalTitle,
            url: fileURL,
            thumbnailPath: thumbnailPath?.path,
            videoID: videoID
        )
        
        downloadManager.addDownload(download)
        
        downloadedFileURL = nil
        downloadedTitle = ""
        newTitle = ""
        
        // Auto-close
        dismiss()
    }
    
    private func updateMetadata(for fileURL: URL, newTitle: String) {
        let metadataURL = getMetadataFileURL()
        var metadata = loadMetadata()
        
        let filename = fileURL.lastPathComponent
        if var trackMetadata = metadata[filename] {
            trackMetadata["title"] = newTitle
            metadata[filename] = trackMetadata
            
            do {
                let data = try JSONEncoder().encode(metadata)
                try data.write(to: metadataURL)
                print("✅ [Metadata] Updated title for: \(filename)")
            } catch {
                print("❌ [Metadata] Failed to update: \(error)")
            }
        }
    }
    
    private func loadMetadata() -> [String: [String: String]] {
        let metadataURL = getMetadataFileURL()
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }
        return metadata
    }
    
    private func getMetadataFileURL() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("audio_metadata.json")
    }
    
    private func extractVideoID(from urlString: String) -> String? {
        if let url = URL(string: urlString) {
            if url.host?.contains("youtu.be") == true {
                return url.lastPathComponent
            } else if url.host?.contains("youtube.com") == true {
                if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                    return queryItems.first(where: { $0.name == "v" })?.value
                }
            }
        }
        return nil
    }
}