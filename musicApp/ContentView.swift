import SwiftUI
import AVFoundation

// MARK: - Main ContentView
struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()
    @StateObject private var playlistManager = PlaylistManager()
    @State private var showFolderPicker = false
    @State private var showYouTubeDownload = false
    @State private var showNowPlaying = false
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    List {
                        PlaylistRow(
                            playlist: playlistManager.everythingPlaylist,
                            audioPlayer: audioPlayer,
                            playlistManager: playlistManager
                        )
                        
                        ForEach(playlistManager.playlists) { playlist in
                            PlaylistRow(
                                playlist: playlist,
                                audioPlayer: audioPlayer,
                                playlistManager: playlistManager
                            )
                        }
                        .onDelete(perform: deletePlaylists)
                    }
                    .listStyle(.plain)
                    
                    if audioPlayer.currentTrack != nil {
                        Color.clear.frame(height: 64)
                    }
                }
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            showYouTubeDownload = true
                        } label: {
                            Image(systemName: "link.badge.plus")
                        }
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showFolderPicker = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                    }
                }
                .sheet(isPresented: $showFolderPicker) {
                    FolderPicker(playlistManager: playlistManager)
                }
                .sheet(isPresented: $showYouTubeDownload) {
                    YouTubeDownloadView(playlistManager: playlistManager)
                }
                
                if audioPlayer.currentTrack != nil {
                    MiniPlayerBar(audioPlayer: audioPlayer, showNowPlaying: $showNowPlaying)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(audioPlayer: audioPlayer, isPresented: $showNowPlaying)
        }
    }
    
    func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            playlistManager.removePlaylist(playlistManager.playlists[index])
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

// MARK: - Full Now Playing View (iOS Music style)
struct NowPlayingView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var isPresented: Bool
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var dominantColors: [Color] = [Color.blue.opacity(0.3), Color.purple.opacity(0.3)]
    @State private var showPlaylistPicker = false
    
    var body: some View {
        ZStack {
            // Dynamic background gradient based on thumbnail
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
                
                // Album artwork
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
                
                Spacer()
                
                // Track info
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
                
                // Playback controls with 2x speed on hold
                // Playback controls - reduce spacing to fit
                HStack(spacing: 20) {
                    // Rewind button (tap = -10s, hold = 2x backward)
                    Button {
                        audioPlayer.skip(seconds: -10)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 28))
                            .foregroundColor(.primary)
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.3)
                            .onEnded { _ in
                                audioPlayer.startRewind()
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { _ in
                                audioPlayer.resumeNormalSpeed()
                            }
                    )
                    
                    // Previous
                    Button {
                        audioPlayer.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.primary)
                    }
                    
                    // Play/Pause
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
                    
                    // Next
                    Button {
                        audioPlayer.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.primary)
                    }
                    
                    // Fast Forward button (tap = +10s, hold = 2x forward)
                    Button {
                        audioPlayer.skip(seconds: 10)
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 28))
                            .foregroundColor(.primary)
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.3)
                            .onEnded { _ in
                                audioPlayer.startFastForward()
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { _ in
                                audioPlayer.resumeNormalSpeed()
                            }
                    )
                }
                .padding(.horizontal, 16) // Add horizontal padding
                .padding(.bottom, 20)
                
                // Volume control
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    
                    Slider(value: $audioPlayer.volume, in: 0...1)
                        .accentColor(.white)
                    
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
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