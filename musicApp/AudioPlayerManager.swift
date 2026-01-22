import Foundation
import AVFoundation

class AudioPlayerManager: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTrack: Track?
    @Published var currentPlaylist: [Track] = []
    @Published var currentIndex: Int = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    
    private var avPlayer: AVPlayer?
    private var playerObserver: Any?
    private var displayLink: CADisplayLink?
    
    override init() {
        super.init()
        setupAudioSession()
        startTimeUpdates()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            print("✅ Audio session configured")
        } catch {
            print("❌ Failed to setup audio session: \(error)")
        }
    }
    
    func loadPlaylist(_ tracks: [Track], shuffle: Bool = false) {
        currentPlaylist = shuffle ? tracks.shuffled() : tracks
        currentIndex = 0
        if !currentPlaylist.isEmpty {
            play(currentPlaylist[0])
        }
    }
    
    func play(_ track: Track) {
        if isPlaying {
            avPlayer?.pause()
            isPlaying = false
        }
        
        stopTimeUpdates()
        removePlayerObserver()
        
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            
            // Use resolved URL
            guard let trackURL = track.resolvedURL() else {
                print("❌ Could not resolve track URL")
                return
            }
            
            _ = trackURL.startAccessingSecurityScopedResource()
            
            let playerItem = AVPlayerItem(url: trackURL)
            avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer?.play()
            
            isPlaying = true
            currentTrack = track
            
            if let index = currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
            
            Task { @MainActor in
                if let duration = try? await playerItem.asset.load(.duration) {
                    self.duration = CMTimeGetSeconds(duration)
                }
            }
            
            setupPlayerObserver()
            startTimeUpdates()
            
            print("▶️ Now playing: \(track.name)")
            
        } catch {
            print("❌ Playback error: \(error)")
        }
    }
    
    func pause() {
        avPlayer?.pause()
        isPlaying = false
    }
    
    func resume() {
        avPlayer?.play()
        isPlaying = true
    }
    
    func stop() {
        avPlayer?.pause()
        avPlayer?.seek(to: .zero)
        stopTimeUpdates()
        removePlayerObserver()
        isPlaying = false
        currentTrack = nil
        currentTime = 0
        duration = 0
    }
    
    func seek(to time: Double) {
        avPlayer?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
    }
    
    func skip(seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration))
        seek(to: newTime)
    }
    
    // MARK: - Fast Forward / Rewind
    
    func setPlaybackRate(_ rate: Float) {
        avPlayer?.rate = rate
        isPlaying = (rate != 0)
    }
    
    func startFastForward() {
        setPlaybackRate(2.0)
    }
    
    func startRewind() {
        setPlaybackRate(-2.0)
    }
    
    func resumeNormalSpeed() {
        setPlaybackRate(1.0)
    }
    
    // MARK: - Playlist Navigation
    
    func next() {
        guard !currentPlaylist.isEmpty else { return }
        currentIndex = (currentIndex + 1) % currentPlaylist.count
        play(currentPlaylist[currentIndex])
    }
    
    func previous() {
        guard !currentPlaylist.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
        } else {
            currentIndex = (currentIndex - 1 + currentPlaylist.count) % currentPlaylist.count
            play(currentPlaylist[currentIndex])
        }
    }
    
    // MARK: - Observers
    
    private func setupPlayerObserver() {
        guard let player = avPlayer else { return }
        
        playerObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.next()
        }
    }
    
    private func removePlayerObserver() {
        if let observer = playerObserver {
            NotificationCenter.default.removeObserver(observer)
            playerObserver = nil
        }
    }
    
    private func startTimeUpdates() {
        stopTimeUpdates()
        displayLink = CADisplayLink(target: self, selector: #selector(updateTime))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    private func stopTimeUpdates() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func updateTime() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let avPlayer = self.avPlayer else { return }
            self.currentTime = CMTimeGetSeconds(avPlayer.currentTime())
        }
    }
    
    deinit {
        stopTimeUpdates()
        removePlayerObserver()
    }
}