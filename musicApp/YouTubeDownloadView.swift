import SwiftUI

struct YouTubeDownloadView: View {
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var embeddedPython = EmbeddedPython.shared  // Change from @StateObject to @ObservedObject
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
                HStack {
                    Image(systemName: detectedSource == .youtube ? "play.rectangle.fill" : "music.note")
                        .font(.title3)
                        .foregroundColor(detectedSource == .youtube ? .red : .green)
                    
                    Text("Download from \(detectedSource == .youtube ? "YouTube" : "Spotify")")
                        .font(.headline)
                }
                
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
                checkClipboardAndStart()
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
    
    private func checkClipboardAndStart() {
        // Check if pasteboard has content without triggering permission
        guard UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings else {
            errorMessage = "No URL found in clipboard"
            return
        }
        
        // Access clipboard
        guard let clipboardString = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardString.isEmpty else {
            errorMessage = "Clipboard is empty"
            return
        }
        
        // Detect and validate source
        guard let (source, videoID) = detectSourceAndExtractID(from: clipboardString) else {
            errorMessage = "Invalid URL format. Please copy a valid YouTube or Spotify link."
            return
        }
        
        youtubeURL = clipboardString
        detectedSource = source
        
        // Check for duplicates BEFORE downloading
        if let existing = downloadManager.findDuplicateByVideoID(videoID: videoID, source: source) {
            errorMessage = "Already downloaded: \(existing.name)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                dismiss()
            }
            return
        }
        
        // Start download after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startDownload(videoID: videoID)
        }
    }
    
    private func detectSourceAndExtractID(from urlString: String) -> (DownloadSource, String)? {
        guard let url = URL(string: urlString) else { return nil }
        let host = url.host?.lowercased() ?? ""
        
        // YouTube detection (multiple formats)
        if host.contains("youtube.com") || host.contains("youtu.be") || host.contains("m.youtube.com") {
            if let videoID = extractYouTubeID(from: url) {
                return (.youtube, videoID)
            }
        }
        
        // Spotify detection (multiple formats)
        if host.contains("spotify.com") || host.contains("open.spotify.com") {
            if let trackID = extractSpotifyID(from: url) {
                return (.spotify, trackID)
            }
        }
        
        return nil
    }
    
    private func extractYouTubeID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        
        // youtu.be/VIDEO_ID
        if host.contains("youtu.be") {
            let pathComponents = url.pathComponents.filter { $0 != "/" }
            return pathComponents.first
        }
        
        // youtube.com/watch?v=VIDEO_ID
        if host.contains("youtube.com") {
            // Check query parameters
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems {
                // Standard format: ?v=VIDEO_ID
                if let videoID = queryItems.first(where: { $0.name == "v" })?.value {
                    return videoID
                }
            }
            
            // youtube.com/embed/VIDEO_ID
            if url.pathComponents.contains("embed"), url.pathComponents.count > 2 {
                return url.pathComponents[2]
            }
            
            // youtube.com/v/VIDEO_ID
            if url.pathComponents.contains("v"), url.pathComponents.count > 2 {
                return url.pathComponents[2]
            }
            
            // youtube.com/shorts/VIDEO_ID
            if url.pathComponents.contains("shorts"), url.pathComponents.count > 2 {
                return url.pathComponents[2]
            }
        }
        
        return nil
    }
    
    private func extractSpotifyID(from url: URL) -> String? {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        
        // open.spotify.com/track/TRACK_ID or spotify.com/track/TRACK_ID
        if let trackIndex = pathComponents.firstIndex(of: "track"), trackIndex + 1 < pathComponents.count {
            var trackID = pathComponents[trackIndex + 1]
            // Remove query parameters if present
            if let queryIndex = trackID.firstIndex(of: "?") {
                trackID = String(trackID[..<queryIndex])
            }
            return trackID
        }
        
        return nil
    }
    
    private func startDownload(videoID: String) {
        // Start background download immediately
        downloadManager.startBackgroundDownload(
            url: youtubeURL,
            videoID: videoID,
            source: detectedSource,
            title: "New Song"
        )
        
        // Close the download view immediately
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
        guard let url = URL(string: urlString) else { return nil }
        
        if detectedSource == .youtube {
            return extractYouTubeID(from: url)
        } else {
            return extractSpotifyID(from: url)
        }
    }
}