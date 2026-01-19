
import Foundation
import AVFoundation


class AudioPlayerManager: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTrack: Track?
    @Published var currentPlaylist: [Track] = []
    @Published var currentIndex: Int = 0

    private var player: AVAudioPlayer?
    private var avPlayer: AVPlayer?
    
    func loadPlaylist(_ tracks: [Track], shuffle: Bool = false) {
        currentPlaylist = shuffle ? tracks.shuffled() : tracks
        currentIndex = 0
        if !currentPlaylist.isEmpty {
            play(currentPlaylist[0])
        }
    }
    

    func play(_ track: Track) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)

            // Start accessing the security-scoped resource
            _ = track.url.startAccessingSecurityScopedResource()

            // Try AVAudioPlayer first (for local, natively supported files)
            player = try AVAudioPlayer(contentsOf: track.url)
            player?.delegate = nil // We'll handle manually for now
            player?.play()
            avPlayer = nil
            isPlaying = true
            currentTrack = track

            // Find index in current playlist
            if let index = currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
        } catch {
            print("AVAudioPlayer failed: \(error.localizedDescription). Trying AVPlayer...")
            // Fallback to AVPlayer for unsupported formats or remote URLs
            avPlayer = AVPlayer(url: track.url)
            avPlayer?.play()
            player = nil
            isPlaying = true
            currentTrack = track

            if let index = currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
        }
    }
    

    func pause() {
        player?.pause()
        avPlayer?.pause()
        isPlaying = false
    }
    

    func resume() {
        player?.play()
        avPlayer?.play()
        isPlaying = true
    }
    

    func stop() {
        player?.stop()
        avPlayer?.pause()
        avPlayer?.seek(to: .zero)
        isPlaying = false
        currentTrack = nil
    }
    
    func next() {
        guard !currentPlaylist.isEmpty else { return }
        currentIndex = (currentIndex + 1) % currentPlaylist.count
        play(currentPlaylist[currentIndex])
    }
    
    func previous() {
        guard !currentPlaylist.isEmpty else { return }
        currentIndex = (currentIndex - 1 + currentPlaylist.count) % currentPlaylist.count
        play(currentPlaylist[currentIndex])
    }
}