import SwiftUI

struct YouTubeDownloadView: View {
    @ObservedObject var downloadManager: DownloadManager
    @State private var errorMessage: String?
    @State private var hasProcessed = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 60))
                            .foregroundColor(.orange)
                        
                        Text(error)
                            .foregroundColor(.red)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button("OK") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top)
                    }
                    .padding(.top, 40)
                } else {
                    ProgressView()
                        .padding(.top, 40)
                    Text("Checking...")
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if !hasProcessed {
                    hasProcessed = true
                    checkClipboardAndStart()
                }
            }
        }
    }
    
    private func checkClipboardAndStart() {
        guard UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings else {
            errorMessage = "No URL found in clipboard"
            return
        }
        
        guard let clipboardString = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardString.isEmpty else {
            errorMessage = "Clipboard is empty"
            return
        }
        
        guard let (source, videoID) = detectSourceAndExtractID(from: clipboardString) else {
            errorMessage = "Invalid URL format.\nPlease copy a valid YouTube or Spotify link."
            return
        }
        
        // Check for duplicates FIRST
        if let existing = downloadManager.findDuplicateByVideoID(videoID: videoID, source: source) {
            errorMessage = "Already downloaded:\n\(existing.name)"
            return // Show this error in the sheet
        }
        
        // No duplicate - start download and dismiss immediately
        downloadManager.startBackgroundDownload(
            url: clipboardString,
            videoID: videoID,
            source: source,
            title: "Loading..."
        )
        
        // Dismiss immediately - banner will show
        dismiss()
    }
    
    private func detectSourceAndExtractID(from urlString: String) -> (DownloadSource, String)? {
        guard let url = URL(string: urlString) else { return nil }
        let host = url.host?.lowercased() ?? ""
        
        if host.contains("youtube.com") || host.contains("youtu.be") || host.contains("m.youtube.com") {
            if let videoID = extractYouTubeID(from: url) {
                return (.youtube, videoID)
            }
        }
        
        if host.contains("spotify.com") || host.contains("open.spotify.com") {
            if let trackID = extractSpotifyID(from: url) {
                return (.spotify, trackID)
            }
        }
        
        return nil
    }
    
    private func extractYouTubeID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        
        if host.contains("youtu.be") {
            let pathComponents = url.pathComponents.filter { $0 != "/" }
            return pathComponents.first
        }
        
        if host.contains("youtube.com") {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems {
                if let videoID = queryItems.first(where: { $0.name == "v" })?.value {
                    return videoID
                }
            }
            
            if url.pathComponents.contains("embed"), url.pathComponents.count > 2 {
                return url.pathComponents[2]
            }
            
            if url.pathComponents.contains("v"), url.pathComponents.count > 2 {
                return url.pathComponents[2]
            }
            
            if url.pathComponents.contains("shorts"), url.pathComponents.count > 2 {
                return url.pathComponents[2]
            }
        }
        
        return nil
    }
    
    private func extractSpotifyID(from url: URL) -> String? {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        
        if let trackIndex = pathComponents.firstIndex(of: "track"), trackIndex + 1 < pathComponents.count {
            var trackID = pathComponents[trackIndex + 1]
            if let queryIndex = trackID.firstIndex(of: "?") {
                trackID = String(trackID[..<queryIndex])
            }
            return trackID
        }
        
        return nil
    }
}