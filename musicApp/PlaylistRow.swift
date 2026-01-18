import SwiftUI

struct PlaylistRow: View {
    let playlist: Playlist
    @ObservedObject var audioPlayer: AudioPlayerManager
    @State private var showTracks = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(playlist.name)
                        .font(.headline)
                    Text("\(playlist.tracks.count) tracks")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                Button {
                    showTracks.toggle()
                } label: {
                    Image(systemName: showTracks ? "chevron.up" : "chevron.down")
                        .foregroundColor(.blue)
                }
            }
            
            HStack(spacing: 20) {
                Button {
                    audioPlayer.loadPlaylist(playlist.tracks, shuffle: false)
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                
                Button {
                    audioPlayer.loadPlaylist(playlist.tracks, shuffle: true)
                } label: {
                    HStack {
                        Image(systemName: "shuffle")
                        Text("Shuffle")
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
            
            if showTracks {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(playlist.tracks) { track in
                        HStack {
                            Image(systemName: "music.note")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(track.name)
                                .font(.caption)
                            Spacer()
                            if audioPlayer.currentTrack?.id == track.id {
                                Image(systemName: audioPlayer.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.leading, 8)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
    }
}