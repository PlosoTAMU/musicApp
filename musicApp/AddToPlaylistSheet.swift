import SwiftUI

struct AddToPlaylistSheet: View {
    let download: Download
    @ObservedObject var playlistManager: PlaylistManager
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()
                
                if playlistManager.playlists.isEmpty {
                    EmptyStateView(
                        icon: "music.note.list",
                        title: "No playlists yet",
                        message: "Create a playlist from the Playlists tab first"
                    )
                } else {
                    List {
                        ForEach(playlistManager.playlists) { playlist in
                            Button {
                                playlistManager.addToPlaylist(playlist.id, downloadID: download.id)
                                onDismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(Theme.smokeRaised)
                                            .frame(width: 36, height: 36)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .strokeBorder(Theme.seam, lineWidth: 1)
                                            )
                                        Image(systemName: "music.note.list")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(Theme.emberLight)
                                    }
                                    
                                    Text(playlist.name)
                                        .font(Theme.body(15, weight: .medium))
                                        .foregroundColor(Theme.bone)
                                        .lineLimit(1)
                                    
                                    Spacer()
                                    
                                    if playlist.trackIDs.contains(download.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 17))
                                            .foregroundColor(Theme.emberLight)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .surfaceCard()
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .buttonStyle(ChipButtonStyle(tint: Theme.boneDim))
                }
            }
        }
    }
}
