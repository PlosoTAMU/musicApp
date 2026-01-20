// MARK: - Updated AudioPlayerManager.swift
import Foundation
import AVFoundation

class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTrack: Track?
    @Published var currentPlaylist: [Track] = []
    @Published var currentIndex: Int = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var player: AVAudioPlayer?
    private var avPlayer: AVPlayer?
    private var timeObserver: Any?
    
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
            
            _ = track.url.startAccessingSecurityScopedResource()
            
            player = try AVAudioPlayer(contentsOf: track.url)
            player?.delegate = self
            player?.play()
            avPlayer = nil
            isPlaying = true
            currentTrack = track
            duration = player?.duration ?? 0
            
            if let index = currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
            
            startTimeObserver()
        } catch {
            print("AVAudioPlayer failed: \(error.localizedDescription). Trying AVPlayer...")
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
        // If more than 3 seconds in, restart current track
        if currentTime > 3 {
            player?.currentTime = 0
            avPlayer?.seek(to: .zero)
        } else {
            currentIndex = (currentIndex - 1 + currentPlaylist.count) % currentPlaylist.count
            play(currentPlaylist[currentIndex])
        }
    }
    
    // Auto-play next track when current finishes
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            next()
        }
    }
    
    private func startTimeObserver() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.currentTime = self.player?.currentTime ?? 0
        }
    }
}