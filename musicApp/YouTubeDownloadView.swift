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
                
                TextField("Paste YouTube URL", text: $youtubeURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(.horizontal)
                
                if downloader.isDownloading {
                    ProgressView("Downloading...")
                        .padding()
                }
                
                if let error = downloader.errorMessage {
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
                        .background(youtubeURL.isEmpty || downloader.isDownloading ? Color.gray : Color.blue)
                        .cornerRadius(10)
                }
                .disabled(youtubeURL.isEmpty || downloader.isDownloading)
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
        downloader.downloadAudio(from: youtubeURL) { track in
            if let track = track {
                playlistManager.addYouTubeTrack(track)
                youtubeURL = ""
                dismiss()
            }
        }
    }
}