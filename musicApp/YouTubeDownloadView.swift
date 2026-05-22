import SwiftUI

struct YouTubeDownloadView: View {
    @ObservedObject var downloadManager: DownloadManager
    @State private var errorMessage: String?
    @State private var hasProcessed = false
    @State private var isPlaylist = false
    @State private var playlistTrackCount: Int?
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
                    setupTitleCallback()
                    checkClipboardAndStart()
                }
            }
            .onDisappear {
                EmbeddedPython.shared.onTitleFetched = nil
            }
        }
    }
    
    private func setupTitleCallback() {
        EmbeddedPython.shared.onTitleFetched = { [weak downloadManager] videoID, title in
            guard let manager = downloadManager else { return }
            
            if let index = manager.activeDownloads.firstIndex(where: { $0.videoID == videoID }) {
                manager.activeDownloads[index] = ActiveDownload(
                    id: manager.activeDownloads[index].id,
                    videoID: videoID,
                    title: title,
                    progress: manager.activeDownloads[index].progress
                )
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
        
        // ✅ FIX: Only treat as playlist if it's a BARE playlist link
        // (has list= but NOT v= for YouTube, or /playlist/ but NOT /track/ for Spotify)
        if isBarePlaylistURL(clipboardString),
        let playlistInfo = downloadManager.detectPlaylist(from: clipboardString) {
            downloadManager.downloadPlaylist(
                url: clipboardString,
                source: playlistInfo.source,
                playlistID: playlistInfo.playlistID
            )
            dismiss()
            return
        }
        
        // Single track download
        guard let (source, videoID) = detectSourceAndExtractID(from: clipboardString) else {
            errorMessage = "Invalid URL format.\nPlease copy a valid YouTube or Spotify link."
            return
        }
        
        if let existing = downloadManager.findDuplicateByVideoID(videoID: videoID, source: source) {
            errorMessage = "Already downloaded:\n\(existing.name)"
            return
        }
        
        downloadManager.startBackgroundDownload(
            url: clipboardString,
            videoID: videoID,
            source: source,
            title: "Fetching info"
        )
        
        dismiss()
    }

    /// Returns true only if the URL is a bare playlist/album link with NO specific video/track
    private func isBarePlaylistURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let host = url.host?.lowercased() ?? ""
        
        // YouTube: has list= but NOT v= → bare playlist
        if host.contains("youtube.com") || host.contains("youtu.be") {
            let hasVideo = components.queryItems?.contains(where: { $0.name == "v" }) == true
            let hasList = components.queryItems?.contains(where: { $0.name == "list" }) == true
            return hasList && !hasVideo
        }
        
        // Spotify: has /playlist/ or /album/ but NOT /track/
        if host.contains("spotify.com") {
            let path = url.pathComponents
            let isTrack = path.contains("track")
            let isList = path.contains("playlist") || path.contains("album")
            return isList && !isTrack
        }
        
        return false
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