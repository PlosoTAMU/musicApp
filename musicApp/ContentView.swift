import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()
    @State private var tracks: [Track] = []
    @State private var showFilePicker = false
    
    var body: some View {
        NavigationView {
            VStack {
                // Playlist
                List {
                    ForEach(tracks) { track in
                        Button {
                            audioPlayer.play(track)
                        } label: {
                            HStack {
                                Image(systemName: "music.note")
                                Text(track.name)
                                Spacer()
                                if audioPlayer.currentTrack?.id == track.id {
                                    Image(systemName: audioPlayer.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                    .onDelete(perform: deleteTracks)
                }
                
                // Controls
                HStack(spacing: 40) {
                    Button {
                        shuffleTracks()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.title)
                    }
                    
                    Button {
                        if audioPlayer.isPlaying {
                            audioPlayer.pause()
                        } else {
                            audioPlayer.resume()
                        }
                    } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                    }
                    
                    Button {
                        audioPlayer.stop()
                    } label: {
                        Image(systemName: "stop.circle")
                            .font(.title)
                    }
                }
                .padding()
            }
            .navigationTitle("Music Shuffler")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFilePicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPicker(tracks: $tracks)
            }
        }
    }
    
    func shuffleTracks() {
        tracks.shuffle()
    }
    
    func deleteTracks(at offsets: IndexSet) {
        tracks.remove(atOffsets: offsets)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}