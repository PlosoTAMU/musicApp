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
            ZStack {
                AppBackground()
                
                VStack(spacing: 0) {
                    // Name input
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.emberLight)
                        
                        TextField(
                            "",
                            text: $playlistName,
                            prompt: Text("Playlist Name")
                                .font(Theme.body(15))
                                .foregroundColor(Theme.boneFaint)
                        )
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundColor(Theme.bone)
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Theme.smoke))
                    .overlay(Capsule().strokeBorder(Theme.seam, lineWidth: 1))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    
                    SectionEyebrow("Add Songs")
                        .padding(.horizontal, 18)
                        .padding(.bottom, 4)
                    
                    List(downloadManager.sortedDownloads) { download in
                        Button {
                            if selectedDownloadIDs.contains(download.id) {
                                selectedDownloadIDs.remove(download.id)
                            } else {
                                selectedDownloadIDs.insert(download.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AsyncThumbnailView(
                                    thumbnailPath: download.resolvedThumbnailPath,
                                    size: 40,
                                    cornerRadius: 9
                                )
                                
                                Text(download.name)
                                    .font(Theme.body(15, weight: .medium))
                                    .foregroundColor(Theme.bone)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                if selectedDownloadIDs.contains(download.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 19))
                                        .foregroundColor(Theme.emberLight)
                                } else {
                                    Image(systemName: "circle")
                                        .font(.system(size: 19))
                                        .foregroundColor(Theme.boneFaint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .buttonStyle(ChipButtonStyle(tint: Theme.boneDim))
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        createPlaylist()
                    }
                    .buttonStyle(ChipButtonStyle(prominent: true))
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
