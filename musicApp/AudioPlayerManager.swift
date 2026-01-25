import Foundation
import AVFoundation
import MediaPlayer

class AudioPlayerManager: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTrack: Track?
    @Published var currentPlaylist: [Track] = []
    @Published var currentIndex: Int = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    
    private var avPlayer: AVPlayer?
    private var playerObserver: Any?
    private var timeObserver: Any?
    
    override init() {
        super.init()
        setupAudioSession()
        setupRemoteControls()
        setupInterruptionHandling()
        setupTimeObserver()
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // CRITICAL FIX: Use .playback mode without .mixWithOthers
            // Also set mode to .spokenAudio which is more reliable for background playback
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
            
            // Request background audio capabilities
            UIApplication.shared.beginReceivingRemoteControlEvents()
            
            print("✅ Audio session configured for background playback")
        } catch {
            print("❌ Failed to setup audio session: \(error)")
        }
    }
    
    private func setupRemoteControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: event.positionTime)
                return .success
            }
            return .commandFailed
        }
        
        // Enable skip forward/backward
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [10]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(seconds: 10)
            return .success
        }
        
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [10]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(seconds: -10)
            return .success
        }
    }
    
    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // CRITICAL: Listen for app state changes to keep audio session active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func handleAppWillResignActive() {
        // CRITICAL FIX: Ensure audio session stays active when app goes to background
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            print("🔊 Audio session kept active on background")
        } catch {
            print("❌ Failed to keep audio session active: \(error)")
        }
    }
    
    @objc private func handleAppDidBecomeActive() {
        // Reactivate audio session when returning to foreground
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            updateNowPlayingInfo()
            print("🔊 Audio session reactivated on foreground")
        } catch {
            print("❌ Failed to reactivate audio session: \(error)")
        }
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            pause()
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones unplugged - pause playback
            pause()
        default:
            break
        }
    }
    
    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.name
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = track.folderName
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        // Add artwork if available
        if let thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: track.url),
           let image = UIImage(contentsOfFile: thumbnailPath.path) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
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
        
        removeTimeObserver()
        removePlayerObserver()
        
        do {
            // CRITICAL: Reactivate audio session before playing
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            
            guard let trackURL = track.resolvedURL() else {
                print("❌ Could not resolve track URL")
                return
            }
            
            _ = trackURL.startAccessingSecurityScopedResource()
            
            let playerItem = AVPlayerItem(url: trackURL)
            
            // CRITICAL FIX: Configure player for background playback
            avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer?.automaticallyWaitsToMinimizeStalling = false
            
            // CRITICAL: Set audio timing to prevent termination
            avPlayer?.currentItem?.preferredForwardBufferDuration = 30
            
            avPlayer?.play()
            
            isPlaying = true
            currentTrack = track
            
            if let index = currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
            
            Task { @MainActor in
                if let duration = try? await playerItem.asset.load(.duration) {
                    self.duration = CMTimeGetSeconds(duration)
                    self.updateNowPlayingInfo()
                }
            }
            
            setupPlayerObserver()
            setupTimeObserver()
            updateNowPlayingInfo()
            
            print("▶️ Now playing: \(track.name)")
            
        } catch {
            print("❌ Playback error: \(error)")
        }
    }
    
    func pause() {
        avPlayer?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }
    
    func resume() {
        // CRITICAL: Ensure audio session is active before resuming
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("❌ Failed to reactivate audio session: \(error)")
        }
        
        avPlayer?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }
    
    func stop() {
        avPlayer?.pause()
        avPlayer?.seek(to: .zero)
        removeTimeObserver()
        removePlayerObserver()
        isPlaying = false
        currentTrack = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    func seek(to time: Double) {
        avPlayer?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
        updateNowPlayingInfo()
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
    
    // MARK: - Time Observer (Replaces CADisplayLink)
    
    private func setupTimeObserver() {
        removeTimeObserver()
        
        // CRITICAL FIX: Use AVPlayer's time observer instead of CADisplayLink
        // CADisplayLink doesn't work in background
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = avPlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = CMTimeGetSeconds(time)
            
            // Update Now Playing info every 5 seconds
            if Int(self.currentTime) % 5 == 0 {
                self.updateNowPlayingInfo()
            }
        }
    }
    
    private func removeTimeObserver() {
        if let observer = timeObserver {
            avPlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
    
    deinit {
        removeTimeObserver()
        removePlayerObserver()
        NotificationCenter.default.removeObserver(self)
    }
}