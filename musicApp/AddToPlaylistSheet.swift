import SwiftUI

struct AddToPlaylistSheet: View {
    let download: Download
    @ObservedObject var playlistManager: PlaylistManager
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationView {
            List {
                ForEach(playlistManager.playlists) { playlist in
                    Button {
                        playlistManager.addToPlaylist(playlist.id, downloadID: download.id)
                        onDismiss()
                    } label: {
                        HStack {
                            Image(systemName: "music.note.list")
                                .foregroundColor(.blue)
                            Text(playlist.name)
                            Spacer()
                            if playlist.trackIDs.contains(download.id) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
            }
        }
    }
}