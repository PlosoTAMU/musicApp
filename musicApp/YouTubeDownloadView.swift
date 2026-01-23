import SwiftUI

struct YouTubeDownloadView: View {
    @ObservedObject var downloadManager: DownloadManager
    @State private var youtubeURL = ""
    @State private var isDownloading = false
    @State private var errorMessage: String?
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
                    ProgressView("Downloading...")
                        .padding()
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
        
        Task {
            do {
                let (fileURL, title) = try await EmbeddedPython.shared.downloadAudio(url: youtubeURL)
                
                // Get thumbnail path if available
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
                    dismiss()
                }
                
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDownloading = false
                }
            }
        }
    }
}