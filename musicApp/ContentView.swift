import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - Main ContentView with TabView
struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var playlistManager = PlaylistManager()
    @State private var showFolderPicker = false
    @State private var showYouTubeDownload = false
    @State private var showNowPlaying = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                DownloadsView(
                    downloadManager: downloadManager,
                    playlistManager: playlistManager,
                    audioPlayer: audioPlayer,
                    showFolderPicker: $showFolderPicker,
                    showYouTubeDownload: $showYouTubeDownload
                )
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                
                PlaylistsView(
                    playlistManager: playlistManager,
                    downloadManager: downloadManager,
                    audioPlayer: audioPlayer
                )
                .tabItem {
                    Label("Playlists", systemImage: "music.note.list")
                }
            }
            
            if audioPlayer.currentTrack != nil {
                MiniPlayerBar(audioPlayer: audioPlayer, showNowPlaying: $showNowPlaying)
                    .transition(.move(edge: .bottom))
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(audioPlayer: audioPlayer, isPresented: $showNowPlaying)
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(downloadManager: downloadManager)
        }
        .sheet(isPresented: $showYouTubeDownload) {
            YouTubeDownloadView(downloadManager: downloadManager)
        }
    }
}

// MARK: - Mini Player Bar
struct MiniPlayerBar: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var showNowPlaying: Bool
    
    var body: some View {
        Button {
            showNowPlaying = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if let thumbnailPath = getThumbnailImage(for: audioPlayer.currentTrack) {
                        Image(uiImage: thumbnailPath)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 48, height: 48)
                            .overlay(
                                Image(systemName: "music.note")
                                    .foregroundColor(.gray)
                            )
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(audioPlayer.currentTrack?.name ?? "Unknown")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    Text(audioPlayer.currentTrack?.folderName ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                
                Button {
                    audioPlayer.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 0.5),
            alignment: .top
        )
        .padding(.bottom, 49)  // Add padding to sit above tab bar
    }
    
    private func getThumbnailImage(for track: Track?) -> UIImage? {
        guard let track = track else { return nil }
        
        // Use Task to bridge to MainActor
        var thumbnailPath: URL?
        let semaphore = DispatchSemaphore(value: 0)
        
        Task {
            let python = await PythonBridge.shared
            thumbnailPath = await python.getThumbnailPath(for: track.url)
            semaphore.signal()
        }
        
        semaphore.wait()
        
        if let path = thumbnailPath,
        let image = UIImage(contentsOfFile: path.path) {
            return image
        }
        return nil
    }
}

// MARK: - System Volume View
struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        volumeView.tintColor = .white
        return volumeView
    }
    
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Rewind Button
struct RewindButton: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var isHolding: Bool
    
    var body: some View {
        Image("rewind")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 24, height: 24)
            .foregroundColor(.primary)
            .gesture(
                LongPressGesture(minimumDuration: 0.3)
                    .onEnded { _ in
                        isHolding = true
                        audioPlayer.startRewind()
                    }
                    .simultaneously(with: DragGesture(minimumDistance: 0)
                        .onEnded { _ in
                            if isHolding {
                                audioPlayer.resumeNormalSpeed()
                                isHolding = false
                            } else {
                                audioPlayer.skip(seconds: -10)
                            }
                        }
                    )
            )
    }
}

// MARK: - Fast Forward Button
struct FastForwardButton: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var isHolding: Bool
    
    var body: some View {
        Image("forward")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 24, height: 24)
            .foregroundColor(.primary)
            .gesture(
                LongPressGesture(minimumDuration: 0.3)
                    .onEnded { _ in
                        isHolding = true
                        audioPlayer.startFastForward()
                    }
                    .simultaneously(with: DragGesture(minimumDistance: 0)
                        .onEnded { _ in
                            if isHolding {
                                audioPlayer.resumeNormalSpeed()
                                isHolding = false
                            } else {
                                audioPlayer.skip(seconds: 10)
                            }
                        }
                    )
            )
    }
}

// MARK: - Full Now Playing View
struct NowPlayingView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var isPresented: Bool
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var dominantColors: [Color] = [Color.blue.opacity(0.3), Color.purple.opacity(0.3)]
    @State private var showPlaylistPicker = false
    @State private var isHoldingRewind = false
    @State private var isHoldingFF = false
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: dominantColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: dominantColors)
            
            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Menu {
                        Button(action: { showPlaylistPicker = true }) {
                            Label("Add to Playlist", systemImage: "plus")
                        }
                        Button(action: {}) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                }
                .padding()
                
                Spacer()
                
                // Album artwork - tappable
                Button {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                } label: {
                    ZStack {
                        if let thumbnailImage = getThumbnailImage(for: audioPlayer.currentTrack) {
                            Image(uiImage: thumbnailImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 320, height: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                                .onAppear {
                                    extractDominantColors(from: thumbnailImage)
                                }
                        } else {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 320, height: 320)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 80))
                                        .foregroundColor(.white.opacity(0.5))
                                )
                                .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
                        }
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Track info - tappable
                Button {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(audioPlayer.currentTrack?.name ?? "Unknown")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        
                        Text(audioPlayer.currentTrack?.folderName ?? "Unknown Album")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Progress bar
                VStack(spacing: 8) {
                    Slider(
                        value: isSeeking ? $seekValue : Binding(
                            get: { audioPlayer.currentTime },
                            set: { _ in }
                        ),
                        in: 0...max(audioPlayer.duration, 1),
                        onEditingChanged: { editing in
                            isSeeking = editing
                            if !editing {
                                audioPlayer.seek(to: seekValue)
                            } else {
                                seekValue = audioPlayer.currentTime
                            }
                        }
                    )
                    .accentColor(.white)
                    
                    HStack {
                        Text(formatTime(isSeeking ? seekValue : audioPlayer.currentTime))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(formatTime(audioPlayer.duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 32)
                
                Spacer()
                
                // Playback controls
                HStack(spacing: 20) {
                    RewindButton(audioPlayer: audioPlayer, isHolding: $isHoldingRewind)
                    
                    Button {
                        audioPlayer.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.primary)
                    }
                    
                    Button {
                        if audioPlayer.isPlaying {
                            audioPlayer.pause()
                        } else {
                            audioPlayer.resume()
                        }
                    } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.primary)
                    }
                    
                    Button {
                        audioPlayer.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.primary)
                    }
                    
                    FastForwardButton(audioPlayer: audioPlayer, isHolding: $isHoldingFF)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                
                // Volume control
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        
                        Spacer()
                        
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    
                    SystemVolumeView()
                        .frame(height: 2)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    // If swiped down more than 100 points, dismiss
                    if value.translation.height > 100 {
                        isPresented = false
                    }
                }
        )
        .sheet(isPresented: $showPlaylistPicker) {
            Text("Playlist picker coming soon")
                .padding()
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func getThumbnailImage(for track: Track?) -> UIImage? {
        guard let track = track,
              let thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: track.url),
              let image = UIImage(contentsOfFile: thumbnailPath.path) else {
            return nil
        }
        return image
    }
    
    private func extractDominantColors(from image: UIImage) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let inputImage = CIImage(image: image) else { return }
            
            let extentVector = CIVector(x: inputImage.extent.origin.x,
                                       y: inputImage.extent.origin.y,
                                       z: inputImage.extent.size.width,
                                       w: inputImage.extent.size.height)
            
            guard let filter = CIFilter(name: "CIAreaAverage",
                                       parameters: [kCIInputImageKey: inputImage,
                                                   kCIInputExtentKey: extentVector]) else { return }
            guard let outputImage = filter.outputImage else { return }
            
            var bitmap = [UInt8](repeating: 0, count: 4)
            let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
            context.render(outputImage,
                          toBitmap: &bitmap,
                          rowBytes: 4,
                          bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                          format: .RGBA8,
                          colorSpace: nil)
            
            let color = Color(red: Double(bitmap[0]) / 255.0,
                            green: Double(bitmap[1]) / 255.0,
                            blue: Double(bitmap[2]) / 255.0)
            
            DispatchQueue.main.async {
                self.dominantColors = [
                    color.opacity(0.6),
                    color.opacity(0.3)
                ]
            }
        }
    }
}