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
    @Published var volume: Double = 0.5 {
        didSet {
            player?.volume = Float(volume)
            avPlayer?.volume = Float(volume)
        }
    }

    private var player: AVAudioPlayer?
    private var avPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var displayLink: CADisplayLink?
    
    override init() {
        super.init()
        startTimeUpdates()
    }
    
    func loadPlaylist(_ tracks: [Track], shuffle: Bool = false) {
        currentPlaylist = shuffle ? tracks.shuffled() : tracks
        currentIndex = 0
        if !currentPlaylist.isEmpty {
            play(currentPlaylist[0])
        }
    }
    
    func play(_ track: Track) {
        // Stop any existing playback
        stopTimeUpdates()
        player?.stop()
        avPlayer?.pause()
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            
            _ = track.url.startAccessingSecurityScopedResource()
            
            player = try AVAudioPlayer(contentsOf: track.url)
            player?.delegate = self
            player?.volume = Float(volume)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            currentTime = 0
            player?.play()
            
            avPlayer = nil
            isPlaying = true
            currentTrack = track
            
            if let index = currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
            
            startTimeUpdates()
        } catch {
            print("AVAudioPlayer failed: \(error.localizedDescription). Trying AVPlayer...")
            let playerItem = AVPlayerItem(url: track.url)
            avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer?.volume = Float(volume)
            avPlayer?.play()
            
            player = nil
            isPlaying = true
            currentTrack = track
            
            if let index = currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
            
            // Get duration for AVPlayer
            Task { @MainActor in
                if let duration = try? await playerItem.asset.load(.duration) {
                    self.duration = CMTimeGetSeconds(duration)
                }
            }
            
            startTimeUpdates()
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
        stopTimeUpdates()
        isPlaying = false
        currentTrack = nil
        currentTime = 0
        duration = 0
    }
    
    func seek(to time: Double) {
        if let player = player {
            player.currentTime = time
            currentTime = time
        } else if let avPlayer = avPlayer {
            avPlayer.seek(to: CMTime(seconds: time, preferredTimescale: 600))
            currentTime = time
        }
    }
    
    func skip(seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration))
        seek(to: newTime)
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
            seek(to: 0)
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
    
    private func startTimeUpdates() {
        stopTimeUpdates()
        
        // Use CADisplayLink for smooth 60fps updates
        displayLink = CADisplayLink(target: self, selector: #selector(updateTime))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    private func stopTimeUpdates() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func updateTime() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let player = self.player {
                self.currentTime = player.currentTime
                self.duration = player.duration
            } else if let avPlayer = self.avPlayer {
                self.currentTime = CMTimeGetSeconds(avPlayer.currentTime())
            }
        }
    }
    
    deinit {
        stopTimeUpdates()
    }
}