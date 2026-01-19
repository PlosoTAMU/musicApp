import SwiftUI

struct YouTubeDownloadView: View {
    @ObservedObject var playlistManager: PlaylistManager
    @StateObject private var downloader = YouTubeDownloader()
    @State private var youtubeURL = ""
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Download from YouTube")
                    .font(.headline)
                
                HStack {
                    TextField("Paste YouTube URL", text: $youtubeURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    
                    // Paste button
                    Button(action: pasteFromClipboard) {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.blue)
                            .padding(8)
                    }
                }
                .padding(.horizontal)
                
                if downloader.isDownloading {
                    ProgressView("Downloading...")
                        .padding()
                }
                
                if let error = downloader.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                downloadButton
                
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
    
    private var downloadButton: some View {
        let isDisabled = youtubeURL.isEmpty || downloader.isDownloading
        let backgroundColor = isDisabled ? Color.gray : Color.blue
        
        return Button {
            startDownload()
        } label: {
            Text("Download Audio")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(backgroundColor)
                .cornerRadius(10)
        }
        .disabled(isDisabled)
        .padding(.horizontal)
    }
    
    private func startDownload() {
        downloader.downloadAudio(from: youtubeURL) { track in
            if let track = track {
                playlistManager.addYouTubeTrack(track)
                youtubeURL = ""
                dismiss()
            }
        }
    }
    
    private func pasteFromClipboard() {
        if let clipboardString = UIPasteboard.general.string {
            youtubeURL = clipboardString
        }
    }
}