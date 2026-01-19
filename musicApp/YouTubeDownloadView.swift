import SwiftUI

struct YouTubeDownloadView: View {
    @ObservedObject var playlistManager: PlaylistManager
    @StateObject private var downloader = YouTubeDownloader()
    @ObservedObject var extractor = YouTubeExtractor.shared
    @ObservedObject var ytdlpService = PythonYTDLPService.shared
    @State private var youtubeURL = ""
    @State private var detectedURL: String? = nil
    @State private var showManualEntry = false
    @State private var showLogin = false
    @State private var showServerConfig = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                
                // Server status / Login status
                HStack {
                    // Server status
                    Button {
                        showServerConfig = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: ytdlpService.isRunning ? "server.rack" : "server.rack")
                                .foregroundColor(ytdlpService.isRunning ? .green : .gray)
                            Text(ytdlpService.isRunning ? "Server" : "Setup Server")
                                .font(.caption)
                                .foregroundColor(ytdlpService.isRunning ? .green : .blue)
                        }
                    }
                    
                    Spacer()
                    
                    // Login status
                    if extractor.isLoggedIn {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("YouTube")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Button("Sign Out") {
                            extractor.logout()
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                    } else {
                        Button {
                            showLogin = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "person.circle")
                                Text("Sign in")
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }
                    }
                }
                .padding(.horizontal)
                
                // Auto-detected URL section
                if let detected = detectedURL, !showManualEntry {
                    VStack(spacing: 16) {
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("YouTube Link Detected!")
                            .font(.headline)
                        
                        Text(detected)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        if downloader.isDownloading {
                            VStack(spacing: 8) {
                                ProgressView(value: extractor.downloadProgress)
                                    .progressViewStyle(LinearProgressViewStyle())
                                    .padding(.horizontal, 40)
                                Text(extractor.statusMessage.isEmpty ? "Downloading..." : extractor.statusMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        } else {
                            // One-tap download button
                            Button {
                                youtubeURL = detected
                                startDownload()
                            } label: {
                                Label("Download Audio", systemImage: "arrow.down.circle.fill")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .cornerRadius(12)
                            }
                            .padding(.horizontal, 40)
                        }
                        
                        Button("Enter URL manually") {
                            showManualEntry = true
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                } else {
                    // Manual entry section
                    VStack(spacing: 16) {
                        Text("Download from YouTube")
                            .font(.headline)
                        
                        HStack {
                            TextField("Paste YouTube URL", text: $youtubeURL)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                            
                            Button(action: pasteFromClipboard) {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundColor(.blue)
                                    .padding(8)
                            }
                        }
                        .padding(.horizontal)
                        
                        if downloader.isDownloading {
                            VStack(spacing: 8) {
                                ProgressView(value: extractor.downloadProgress)
                                    .progressViewStyle(LinearProgressViewStyle())
                                Text(extractor.statusMessage.isEmpty ? "Downloading..." : extractor.statusMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        }
                        
                        downloadButton
                        
                        if detectedURL != nil {
                            Button("Use detected link") {
                                showManualEntry = false
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }
                    }
                }
                
                if let error = downloader.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                Spacer()
            }
            .padding(.top, 30)
            .navigationTitle("YouTube Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                checkClipboardForYouTubeLink()
            }
            .sheet(isPresented: $showLogin) {
                YouTubeLoginView(extractor: extractor)
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
                detectedURL = nil
                dismiss()
            }
        }
    }
    
    private func pasteFromClipboard() {
        if let clipboardString = UIPasteboard.general.string {
            youtubeURL = clipboardString
        }
    }
    
    private func checkClipboardForYouTubeLink() {
        guard let clipboardString = UIPasteboard.general.string else { return }
        
        // Check if it looks like a YouTube URL
        let youtubePatterns = [
            "youtube.com/watch",
            "youtu.be/",
            "youtube.com/shorts/",
            "youtube.com/embed/",
            "music.youtube.com/"
        ]
        
        for pattern in youtubePatterns {
            if clipboardString.contains(pattern) {
                detectedURL = clipboardString
                print("🔗 [YouTubeDownload] Detected YouTube URL in clipboard")
                return
            }
        }
    }
}