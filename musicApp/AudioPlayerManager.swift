import Foundation
import AVFoundation

class AudioPlayerManager: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTrack: Track?
    
    private var player: AVAudioPlayer?
    
    func play(_ track: Track) {
        do {
            // Required to allow audio playback
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            
            player = try AVAudioPlayer(contentsOf: track.url)
            player?.play()
            isPlaying = true
            currentTrack = track
        } catch {
            print("Playback error: \(error.localizedDescription)")
        }
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
    }
    
    func resume() {
        player?.play()
        isPlaying = true
    }
    
    func stop() {
        player?.stop()
        isPlaying = false
        currentTrack = nil
    }
}