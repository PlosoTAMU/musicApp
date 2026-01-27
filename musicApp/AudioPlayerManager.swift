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
    @Published var reverbAmount: Double = 0 {
        didSet { applyReverb() }
    }
    @Published var playbackSpeed: Double = 1.0 {
        didSet { applyPlaybackSpeed() }
    }
    
    private var currentPlaybackSessionID = UUID() // Track current playback session
    
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var reverbNode: AVAudioUnitReverb?
    private var timePitchNode: AVAudioUnitTimePitch?
    
    private var playerObserver: Any?
    private var timeObserver: Any?
    private var displayLink: CADisplayLink?
    private var seekOffset: TimeInterval = 0
    
    override init() {
        super.init()
        setupAudioEngine()
        setupAudioSession()
        setupRemoteControls()
        setupInterruptionHandling()
    }
    
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        reverbNode = AVAudioUnitReverb()
        timePitchNode = AVAudioUnitTimePitch()
        
        guard let engine = audioEngine,
              let player = playerNode,
              let reverb = reverbNode,
              let timePitch = timePitchNode else { return }
        
        // Attach nodes
        engine.attach(player)
        engine.attach(reverb)
        engine.attach(timePitch)
        
        // Configure reverb
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 0
        
        // Configure time pitch
        timePitchNode?.rate = 1.0
        
        print("✅ Audio engine configured")
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
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
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            print("📊 Audio session kept active on background")
        } catch {
            print("❌ Failed to keep audio session active: \(error)")
        }
    }
    
    @objc private func handleAppDidBecomeActive() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            updateNowPlayingInfo()
            print("📊 Audio session reactivated on foreground")
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
        
        if let thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: track.url),
           let image = UIImage(contentsOfFile: thumbnailPath.path) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func loadPlaylist(_ tracks: [Track], shuffle: Bool = false) {
        // Stop current playback completely to avoid completion handler race conditions
        if isPlaying {
            playerNode?.stop()
            audioEngine?.stop()
            isPlaying = false
        }
        
        currentPlaylist = shuffle ? tracks.shuffled() : tracks
        currentIndex = 0
        if !currentPlaylist.isEmpty {
            play(currentPlaylist[0])
        }
    }
    
    func play(_ track: Track) {
        // Create new playback session
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        if isPlaying {
            playerNode?.stop()
            audioEngine?.stop()
            isPlaying = false
        }
        
        stopTimeUpdates()

        seekOffset = 0
        
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            
            guard let trackURL = track.resolvedURL() else {
                print("❌ Could not resolve track URL")
                return
            }
            
            _ = trackURL.startAccessingSecurityScopedResource()
            
            // Load audio file
            audioFile = try AVAudioFile(forReading: trackURL)
            
            guard let file = audioFile,
                  let engine = audioEngine,
                  let player = playerNode,
                  let reverb = reverbNode,
                  let timePitch = timePitchNode else {
                print("❌ Audio nodes not configured")
                return
            }
            
            let format = file.processingFormat
            
            // Connect nodes: player -> timePitch -> reverb -> output
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
            
            // Start engine
            try engine.start()
            
            // Schedule file
            player.scheduleFile(file, at: nil) { [weak self] in
                guard let self = self else { return }
                // Only advance if this is still the active playback session
                DispatchQueue.main.async {
                    if self.currentPlaybackSessionID == sessionID && self.isPlaying {
                        self.next()
                    }
                }
            }
            
            // Start playback
            player.play()
            
            isPlaying = true
            currentTrack = track
            
            if let index = currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
            
            // Get duration
            let frameCount = Double(file.length)
            let sampleRate = file.fileFormat.sampleRate
            duration = frameCount / sampleRate
            
            startTimeUpdates()
            updateNowPlayingInfo()
            
            print("▶️ Now playing: \(track.name)")
            
        } catch {
            print("❌ Playback error: \(error)")
        }
    }
    
    func pause() {
        playerNode?.pause()
        isPlaying = false
        stopTimeUpdates()
        updateNowPlayingInfo()
    }
    
    func resume() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("❌ Failed to reactivate audio session: \(error)")
        }
        
        playerNode?.play()
        isPlaying = true
        startTimeUpdates()
        updateNowPlayingInfo()
    }
    
    func stop() {
        playerNode?.stop()
        audioEngine?.stop()
        stopTimeUpdates()
        isPlaying = false
        currentTrack = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    func seek(to time: Double) {
        guard let file = audioFile,
              let player = playerNode else { return }
        
        // Invalidate current session to prevent old completion handler from firing
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        let sampleRate = file.fileFormat.sampleRate
        let startFrame = AVAudioFramePosition(time * sampleRate)
        
        // Pause updates to prevent UI fighting
        pauseTimeUpdates()
        
        // Stop the player
        player.stop()
        
        if startFrame < file.length {
            let remainingFrames = AVAudioFrameCount(file.length - startFrame)
            
            // Schedule segment WITH completion handler for natural playback continuation
            player.scheduleSegment(file, 
                                 startingFrame: startFrame, 
                                 frameCount: remainingFrames, 
                                 at: nil,
                                 completionHandler: { [weak self] in
                                     guard let self = self else { return }
                                     // Only advance if this session is still active
                                     DispatchQueue.main.async {
                                         if self.currentPlaybackSessionID == sessionID && self.isPlaying {
                                             self.next()
                                         }
                                     }
                                 })
            
            if isPlaying {
                player.play()
            }
        }
        
        // Save the new offset so the slider works correctly
        self.seekOffset = time
        
        // Update UI immediately
        self.currentTime = time
        updateNowPlayingInfo()
        
        resumeTimeUpdates()
    }
    
    func skip(seconds: Double) {
        let newTime = currentTime + seconds
        seek(to: newTime) // This reuses your fixed seek() logic which handles offset correctly
    }
    
    // MARK: - Fast Forward / Rewind with 2x speed
    
    func setPlaybackRate(_ rate: Float) {
        timePitchNode?.rate = rate
        isPlaying = (rate != 0)
    }
    
    func startFastForward() {
        setPlaybackRate(2.0)
    }
    
    func startRewind() {
        // Rewind is not directly supported, so skip backward rapidly
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self, self.isPlaying else {
                timer.invalidate()
                return
            }
            self.skip(seconds: -1)
        }
    }
    
    func resumeNormalSpeed() {
        setPlaybackRate(Float(playbackSpeed))
    }
    
    // MARK: - Audio Effects (WORKING)
    
    private func applyReverb() {
        reverbNode?.wetDryMix = Float(reverbAmount)
        print("🎚️ Reverb set to: \(reverbAmount)%")
    }
    
    private func applyPlaybackSpeed() {
        timePitchNode?.rate = Float(playbackSpeed)
        updateNowPlayingInfo()
        print("⚡ Playback speed set to: \(playbackSpeed)x")
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
    
    // MARK: - Time Updates
    
    private func startTimeUpdates() {
        stopTimeUpdates()
        
        displayLink = CADisplayLink(target: self, selector: #selector(updateTime))
        displayLink?.preferredFramesPerSecond = 2 // Update twice per second
        displayLink?.add(to: .main, forMode: .common)
    }
    
    private func stopTimeUpdates() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    // MARK: - Seeking Support
    
    func pauseTimeUpdates() {
        stopTimeUpdates()
    }
    
    func resumeTimeUpdates() {
        if isPlaying {
            startTimeUpdates()
        }
    }
    
    @objc private func updateTime() {
        guard let player = playerNode,
              let file = audioFile,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return
        }
        
        let sampleRate = file.fileFormat.sampleRate
        let currentSegmentTime = Double(playerTime.sampleTime) / sampleRate
        
        // CRITICAL FIX: Add the offset to the current segment time
        currentTime = seekOffset + currentSegmentTime
        
        if Int(currentTime) % 5 == 0 {
            updateNowPlayingInfo()
        }
    }
    
    deinit {
        stopTimeUpdates()
        NotificationCenter.default.removeObserver(self)
    }
}