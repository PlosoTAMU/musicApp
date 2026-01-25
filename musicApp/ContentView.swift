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
        GeometryReader { geometry in
            ZStack {
                // Blurred background from album art
                if let thumbnailImage = getThumbnailImage(for: audioPlayer.currentTrack) {
                    Image(uiImage: thumbnailImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: 80)
                        .scaleEffect(1.2)
                        .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
                
                // Dark overlay for readability
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Top bar
                    HStack {
                        Button {
                            isPresented = false
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.title2)
                                .foregroundColor(.white)
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
                                .foregroundColor(.white)
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
                                    .shadow(color: .black.opacity(0.5), radius: 30, y: 15)
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
                                    .shadow(color: .black.opacity(0.3), radius: 30, y: 15)
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
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            Text(audioPlayer.currentTrack?.folderName ?? "Unknown Album")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.7))
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
                                .foregroundColor(.white.opacity(0.7))
                            
                            Spacer()
                            
                            Text(formatTime(audioPlayer.duration))
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
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
                                .foregroundColor(.white)
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
                                .foregroundColor(.white)
                        }
                        
                        Button {
                            audioPlayer.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.white)
                        }
                        
                        FastForwardButton(audioPlayer: audioPlayer, isHolding: $isHoldingFF)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    
                    // Volume control
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill")
                                .foregroundColor(.white.opacity(0.7))
                                .font(.caption)
                            
                            VolumeSlider()
                                .frame(height: 20)
                            
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.white.opacity(0.7))
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
            }
        }
        .gesture(
            DragGesture()
                .onEnded { value in
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
}

// MARK: - Mini Player Bar
struct MiniPlayerBar: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var showNowPlaying: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail and track info (tappable to open full view)
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
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Play/Pause button
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
            
            // Next button
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
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 0.5),
            alignment: .top
        )
        .padding(.bottom, 49)  // Sit above tab bar
    }
    
    private func getThumbnailImage(for track: Track?) -> UIImage? {
        guard let track = track,
              let thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: track.url),
              let image = UIImage(contentsOfFile: thumbnailPath.path) else {
            return nil
        }
        return image
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
    @State private var showPlaylistPicker = false
    @State private var isHoldingRewind = false
    @State private var isHoldingFF = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Blurred background from album art
                if let thumbnailImage = getThumbnailImage(for: audioPlayer.currentTrack) {
                    Image(uiImage: thumbnailImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: 80)
                        .scaleEffect(1.2)
                        .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
                
                // Dark overlay for readability
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Top bar
                    HStack {
                        Button {
                            isPresented = false
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.title2)
                                .foregroundColor(.white)
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
                                .foregroundColor(.white)
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
                                    .shadow(color: .black.opacity(0.5), radius: 30, y: 15)
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
                                    .shadow(color: .black.opacity(0.3), radius: 30, y: 15)
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
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            Text(audioPlayer.currentTrack?.folderName ?? "Unknown Album")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.7))
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
                                .foregroundColor(.white.opacity(0.7))
                            
                            Spacer()
                            
                            Text(formatTime(audioPlayer.duration))
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
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
                                .foregroundColor(.white)
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
                                .foregroundColor(.white)
                        }
                        
                        Button {
                            audioPlayer.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.white)
                        }
                        
                        FastForwardButton(audioPlayer: audioPlayer, isHolding: $isHoldingFF)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    
                    // Volume control
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill")
                                .foregroundColor(.white.opacity(0.7))
                                .font(.caption)
                            
                            VolumeSlider()
                                .frame(height: 20)
                            
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.white.opacity(0.7))
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
            }
        }
        .gesture(
            DragGesture()
                .onEnded { value in
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
}


// MARK: - Custom Volume Slider
struct VolumeSlider: UIViewRepresentable {
    class Coordinator: NSObject {
        var parent: VolumeSlider
        
        init(_ parent: VolumeSlider) {
            self.parent = parent
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        volumeView.setVolumeThumbImage(UIImage(), for: .normal)
        
        // Find and configure the slider
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.minimumTrackTintColor = .white
                slider.maximumTrackTintColor = .white.withAlphaComponent(0.3)
                slider.isContinuous = true
                
                // Create custom thumb image for better visibility
                let thumbSize: CGFloat = 14
                let thumbImage = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize)).image { context in
                    UIColor.white.setFill()
                    let rect = CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize)
                    context.cgContext.fillEllipse(in: rect)
                    
                    // Add shadow for better visibility
                    context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.3).cgColor)
                }
                slider.setThumbImage(thumbImage, for: .normal)
                slider.setThumbImage(thumbImage, for: .highlighted)
            }
        }
        
        return volumeView
    }
    
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct DownloadBanner: View {
    let activeDownloads: [ActiveDownload]
    @State private var dotCount = 0
    
    var body: some View {
        VStack(spacing: 8) {
            ForEach(activeDownloads) { download in
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    
                    Text("Downloading \(download.title)\(String(repeating: ".", count: dotCount))")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 50)
        .onAppear {
            startAnimation()
        }
    }
    
    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }
}