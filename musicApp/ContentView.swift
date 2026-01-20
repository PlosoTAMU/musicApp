// MARK: - Updated ContentView.swift
import SwiftUI

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
                            audioPlayer: audioPlayer
                        )
                        
                        ForEach(playlistManager.playlists) { playlist in
                            PlaylistRow(
                                playlist: playlist,
                                audioPlayer: audioPlayer
                            )
                        }
                        .onDelete(perform: deletePlaylists)
                    }
                    .listStyle(.plain)
                    
                    // Add bottom padding when mini player is showing
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
                
                // Mini Player Bar (persistent at bottom)
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

// MARK: - Mini Player Bar (iOS Music style)
struct MiniPlayerBar: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var showNowPlaying: Bool
    
    var body: some View {
        Button {
            showNowPlaying = true
        } label: {
            HStack(spacing: 12) {
                // Album artwork placeholder
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundColor(.gray)
                    )
                
                // Track info
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
}

// MARK: - Full Now Playing View (iOS Music style)
struct NowPlayingView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var isPresented: Bool
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
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
                        Button(action: {}) {
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
                
                // Playback controls
                HStack(spacing: 60) {
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
                            .font(.system(size: 72))
                            .foregroundColor(.primary)
                    }
                    
                    Button {
                        audioPlayer.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.primary)
                    }
                }
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
                .padding(.bottom, 10)
                
                // Bottom controls
                HStack {
                    Button(action: {}) {
                        Image(systemName: "quote.bubble")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {}) {
                        Image(systemName: "airplayaudio")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {}) {
                        Image(systemName: "list.bullet")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 30)
            }
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}