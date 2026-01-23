import SwiftUI

struct CreatePlaylistSheet: View {
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    let onDismiss: () -> Void
    
    @State private var playlistName = ""
    @State private var selectedDownloadIDs: Set<UUID> = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Name input
                TextField("Playlist Name", text: $playlistName)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                
                Divider()
                
                // Song selection
                List(downloadManager.sortedDownloads) { download in
                    Button {
                        if selectedDownloadIDs.contains(download.id) {
                            selectedDownloadIDs.remove(download.id)
                        } else {
                            selectedDownloadIDs.insert(download.id)
                        }
                    } label: {
                        HStack {
                            // Thumbnail
                            ZStack {
                                if let thumbPath = download.thumbnailPath,
                                   let image = UIImage(contentsOfFile: thumbPath) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 40, height: 40)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(width: 40, height: 40)
                                        .overlay(
                                            Image(systemName: "music.note")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                        )
                                }
                            }
                            
                            Text(download.name)
                                .font(.body)
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            if selectedDownloadIDs.contains(download.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        createPlaylist()
                    }
                    .disabled(playlistName.isEmpty)
                }
            }
        }
    }
    
    private func createPlaylist() {
        let playlist = playlistManager.createPlaylist(name: playlistName)
        for downloadID in selectedDownloadIDs {
            playlistManager.addToPlaylist(playlist.id, downloadID: downloadID)
        }
        onDismiss()
    }
}