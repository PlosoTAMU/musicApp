import SwiftUI

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
    @State private var detectedSource: DownloadSource = .youtube
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Download from \(detectedSource == .youtube ? "YouTube" : "Spotify")")
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
            .navigationTitle("Download")
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
                // Check if pasteboard has URLs without triggering permission
                if UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings {
                    // Now access it (this MAY trigger permission on first use)
                    if let clipboardString = UIPasteboard.general.string,
                    !clipboardString.isEmpty,
                    (clipboardString.contains("youtube.com") || 
                        clipboardString.contains("youtu.be") || 
                        clipboardString.contains("spotify.com")) {
                        youtubeURL = clipboardString
                        
                        // Detect source
                        if clipboardString.contains("spotify.com") {
                            detectedSource = .spotify
                        } else {
                            detectedSource = .youtube
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            startDownload()
                        }
                    }
                }
            }
        }
        .alert("Rename Song", isPresented: $showRenameAlert, actions: {
            TextField("Song Title", text: $newTitle)
                .autocapitalization(.words)
            
            Button("Cancel", role: .cancel) {
                finishDownload(keepOriginalName: true)
            }
            
            Button("Save") {
                finishDownload(keepOriginalName: false)
            }
        }, message: {
            Text("Enter a new title for this song")
        })
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
        
        // Check for duplicates more thoroughly
        if let existing = downloadManager.hasDuplicate(videoID: videoID, url: URL(fileURLWithPath: videoID)) {
            errorMessage = "Already downloaded: \(existing.name)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                dismiss()
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
                
                // Check again for duplicates after download (by file)
                if let existing = downloadManager.hasDuplicate(videoID: videoID, url: fileURL) {
                    // Delete the newly downloaded file
                    try? FileManager.default.removeItem(at: fileURL)
                    
                    await MainActor.run {
                        errorMessage = "Duplicate detected: \(existing.name)"
                        isDownloading = false
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            dismiss()
                        }
                    }
                    return
                }
                
                let thumbnailPath = embeddedPython.getThumbnailPath(for: fileURL)
                
                await MainActor.run {
                    downloadedFileURL = fileURL
                    downloadedTitle = title
                    newTitle = title
                    youtubeURL = ""
                    isDownloading = false
                    
                    // Show rename dialog with pre-selected text
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        showRenameAlert = true
                    }
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
        
        if !keepOriginalName && finalTitle != downloadedTitle && !finalTitle.isEmpty {
            updateMetadata(for: fileURL, newTitle: finalTitle)
        }
        
        let download = Download(
            name: finalTitle.isEmpty ? downloadedTitle : finalTitle,
            url: fileURL,
            thumbnailPath: thumbnailPath?.path,
            videoID: videoID,
            source: detectedSource
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
            // YouTube
            if url.host?.contains("youtu.be") == true {
                return url.lastPathComponent
            } else if url.host?.contains("youtube.com") == true {
                if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                    return queryItems.first(where: { $0.name == "v" })?.value
                }
            }
            // Spotify
            else if url.host?.contains("spotify.com") == true {
                let components = url.pathComponents
                if let trackIndex = components.firstIndex(of: "track"), trackIndex + 1 < components.count {
                    return components[trackIndex + 1]
                }
            }
        }
        return nil
    }
}