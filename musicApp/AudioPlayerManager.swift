import Foundation
import AVFoundation
import MediaPlayer

class AudioPlayerManager: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTrack: Track?
    @Published var currentPlaylist: [Track] = []
    @Published var queue: [Track] = []
    @Published var isPlaylistMode = false
    @Published var isLoopEnabled = false
    @Published var currentIndex: Int = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var reverbAmount: Double = 0 {
        didSet { applyReverb() }
    }
    @Published var playbackSpeed: Double = 1.0 {
        didSet { applyPlaybackSpeed() }
    }
    
    var savedPlaybackSpeed: Double = 1.0
    private var currentPlaybackSessionID = UUID()
    
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var reverbNode: AVAudioUnitReverb?
    private var timePitchNode: AVAudioUnitTimePitch?
    
    private var playerObserver: Any?
    private var timeObserver: Any?
    private var displayLink: CADisplayLink?
    private var seekOffset: TimeInterval = 0
    
    // FIXED: Track engine state
    private var isEngineRunning = false
    
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
        
        engine.attach(player)
        engine.attach(reverb)
        engine.attach(timePitch)
        
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 0
        
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
        
        // FIXED: Listen for engine configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
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
            print("🎧 Audio interruption began")
            pause()
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            print("🎧 Audio interruption ended")
            
            // FIXED: Restart engine before resuming
            if options.contains(.shouldResume) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.ensureEngineRunning()
                    self?.resume()
                }
            }
        @unknown default:
            break
        }
    }
    
    // FIXED: Handle Bluetooth connect/disconnect
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        print("🎧 Audio route changed: \(reason.rawValue)")
        
        switch reason {
        case .oldDeviceUnavailable:
            print("🎧 Audio device disconnected (headphones/bluetooth)")
            pause()
            
        case .newDeviceAvailable:
            print("🎧 New audio device connected")
            // FIXED: Restart engine when bluetooth connects
            ensureEngineRunning()
            
        case .categoryChange:
            print("🎧 Audio category changed")
            ensureEngineRunning()
            
        default:
            break
        }
    }
    
    // FIXED: Handle engine configuration changes (sample rate, channel count, etc.)
    @objc private func handleEngineConfigurationChange(notification: Notification) {
        print("⚙️ Audio engine configuration changed")
        
        guard let engine = audioEngine,
              let player = playerNode,
              let currentFile = audioFile else { return }
        
        // Stop playback
        player.stop()
        isEngineRunning = false
        
        // Restart engine with new configuration
        do {
            try engine.start()
            isEngineRunning = true
            
            // If we were playing, resume from where we left off
            if isPlaying {
                let wasPlaying = isPlaying
                isPlaying = false
                
                // Re-schedule the file
                let sessionID = currentPlaybackSessionID
                player.scheduleFile(currentFile, at: nil) { [weak self] in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if self.currentPlaybackSessionID == sessionID && self.isPlaying {
                            self.next()
                        }
                    }
                }
                
                if wasPlaying {
                    player.play()
                    isPlaying = true
                    startTimeUpdates()
                }
                
                print("✅ Engine restarted after configuration change")
            }
        } catch {
            print("❌ Failed to restart engine after configuration change: \(error)")
        }
    }
    
    // FIXED: Ensure engine is running before playing
    private func ensureEngineRunning() {
        guard let engine = audioEngine else { return }
        
        if !engine.isRunning {
            print("⚠️ Engine not running, starting...")
            do {
                try engine.start()
                isEngineRunning = true
                print("✅ Engine started successfully")
            } catch {
                print("❌ Failed to start engine: \(error)")
            }
        } else {
            isEngineRunning = true
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
        if isPlaying {
            playerNode?.stop()
            audioEngine?.stop()
            isPlaying = false
            isEngineRunning = false
        }
        
        isPlaylistMode = true
        currentPlaylist = shuffle ? tracks.shuffled() : tracks
        currentIndex = 0
        if !currentPlaylist.isEmpty {
            play(currentPlaylist[0])
        }
    }
    
    func play(_ track: Track) {
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        if isPlaying {
            playerNode?.stop()
            audioEngine?.stop()
            isPlaying = false
            isEngineRunning = false
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
            
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
            
            // FIXED: Ensure engine is running
            ensureEngineRunning()
            
            player.scheduleFile(file, at: nil) { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if self.currentPlaybackSessionID == sessionID && self.isPlaying {
                        self.next()
                    }
                }
            }
            
            player.play()
            
            isPlaying = true
            currentTrack = track
            
            if let index = currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
            
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
        
        // FIXED: Ensure engine is running before playing
        ensureEngineRunning()
        
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
        isEngineRunning = false
        currentTrack = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    func seek(to time: Double) {
        guard let file = audioFile,
              let player = playerNode else { return }
        
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        let sampleRate = file.fileFormat.sampleRate
        let startFrame = AVAudioFramePosition(time * sampleRate)
        
        pauseTimeUpdates()
        
        player.stop()
        
        // FIXED: Ensure engine is running after stop
        ensureEngineRunning()
        
        if startFrame < file.length {
            let remainingFrames = AVAudioFrameCount(file.length - startFrame)
            
            player.scheduleSegment(file, 
                                 startingFrame: startFrame, 
                                 frameCount: remainingFrames, 
                                 at: nil,
                                 completionHandler: { [weak self] in
                                     guard let self = self else { return }
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
        
        self.seekOffset = time
        self.currentTime = time
        updateNowPlayingInfo()
        
        resumeTimeUpdates()
    }
    
    func skip(seconds: Double) {
        let newTime = currentTime + seconds
        seek(to: newTime)
    }
    
    func setPlaybackRate(_ rate: Float) {
        timePitchNode?.rate = rate
        isPlaying = (rate != 0)
    }
    
    func startFastForward() {
        setPlaybackRate(2.0)
    }
    
    func startRewind() {
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
    
    private func applyReverb() {
        reverbNode?.wetDryMix = Float(reverbAmount)
        print("🎚️ Reverb set to: \(reverbAmount)%")
    }
    
    private func applyPlaybackSpeed() {
        timePitchNode?.rate = Float(playbackSpeed)
        if playbackSpeed != 2.0 {
            savedPlaybackSpeed = playbackSpeed
        }
        updateNowPlayingInfo()
        print("⚡ Playback speed set to: \(playbackSpeed)x")
    }
    
    func next() {
        if isLoopEnabled {
            seek(to: 0)
            return
        }
        
        if isPlaylistMode {
            guard !currentPlaylist.isEmpty else { return }
            currentIndex = (currentIndex + 1) % currentPlaylist.count
            play(currentPlaylist[currentIndex])
        } else {
            if !queue.isEmpty {
                let nextTrack = queue.removeFirst()
                play(nextTrack)
            } else {
                stop()
            }
        }
    }
    
    func previous() {
        if isPlaylistMode {
            guard !currentPlaylist.isEmpty else { return }
            if currentTime > 3 {
                seek(to: 0)
            } else {
                currentIndex = (currentIndex - 1 + currentPlaylist.count) % currentPlaylist.count
                play(currentPlaylist[currentIndex])
            }
        } else {
            if currentTime > 3 {
                seek(to: 0)
            } else {
                seek(to: 0)
            }
        }
    }
    
    var upNextTracks: [Track] {
        if isPlaylistMode && !currentPlaylist.isEmpty {
            let nextIndex = currentIndex + 1
            if nextIndex < currentPlaylist.count {
                return Array(currentPlaylist[nextIndex...])
            }
        }
        return []
    }
    
    func addToQueue(_ track: Track) {
        queue.append(track)
        
        if currentTrack == nil {
            isPlaylistMode = false
            let firstTrack = queue.removeFirst()
            play(firstTrack)
        }
    }
    
    func playNext(_ track: Track) {
        queue.insert(track, at: 0)
        
        if currentTrack == nil {
            isPlaylistMode = false
            let firstTrack = queue.removeFirst()
            play(firstTrack)
        }
    }
    
    func removeFromQueue(at offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
    }
    
    func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }
    
    func clearQueue() {
        queue.removeAll()
    }
    
    func playFromQueue(_ track: Track) {
        if let index = queue.firstIndex(where: { $0.id == track.id }) {
            queue.remove(at: index)
        }
        
        isPlaylistMode = false
        play(track)
    }
    
    private func startTimeUpdates() {
        stopTimeUpdates()
        
        displayLink = CADisplayLink(target: self, selector: #selector(updateTime))
        displayLink?.preferredFramesPerSecond = 2
        displayLink?.add(to: .main, forMode: .common)
    }
    
    private func stopTimeUpdates() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
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