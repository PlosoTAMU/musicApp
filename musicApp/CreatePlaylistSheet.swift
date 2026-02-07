import SwiftUI

struct CreatePlaylistSheet: View {
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    let onDismiss: () -> Void
    
    @State private var playlistName = "New Playlist"
    @State private var selectedDownloadIDs: Set<UUID> = []
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Name input
                HStack {
                    TextField("Playlist Name", text: $playlistName, onEditingChanged: { isEditing in
                        if isEditing {
                            DispatchQueue.main.async {
                                let textField = UITextField.appearance()
                            }
                        }
                    })
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFieldFocused)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            isTextFieldFocused = true
                        }
                    }
                    .onTapGesture {
                        if isTextFieldFocused {
                            DispatchQueue.main.async {
                                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                            }
                        }
                    }
                }
                .padding()
                
                Divider()
                
                // ✅ FIXED: Use async thumbnail loading and proper list styling
                List(downloadManager.sortedDownloads) { download in
                    Button {
                        if selectedDownloadIDs.contains(download.id) {
                            selectedDownloadIDs.remove(download.id)
                        } else {
                            selectedDownloadIDs.insert(download.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            // ✅ FIXED: Use AsyncThumbnailView instead of synchronous loading
                            AsyncThumbnailView(
                                thumbnailPath: download.resolvedThumbnailPath,
                                size: 40,
                                cornerRadius: 6
                            )
                            
                            Text(download.name)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
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
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.black)
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