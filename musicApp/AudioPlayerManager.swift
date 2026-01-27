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
    
    private var isEngineRunning = false
    
    // FIXED: Callback for when playback ends naturally (no more songs)
    var onPlaybackEnded: (() -> Void)?
    
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
            DispatchQueue.main.async {
                self.pause()
            }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            print("🎧 Audio interruption ended")
            
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
            DispatchQueue.main.async {
                self.pause()
            }
            
        case .newDeviceAvailable:
            print("🎧 New audio device connected")
            ensureEngineRunning()
            
        case .categoryChange:
            print("🎧 Audio category changed")
            ensureEngineRunning()
            
        default:
            break
        }
    }
    
    // FIXED: All UI updates wrapped in DispatchQueue.main.async
    @objc private func handleEngineConfigurationChange(notification: Notification) {
        print("⚙️ Audio engine configuration changed")
        
        guard let engine = audioEngine,
              let player = playerNode,
              let currentFile = audioFile else { return }
        
        player.stop()
        isEngineRunning = false
        
        do {
            try engine.start()
            isEngineRunning = true
            
            if isPlaying {
                let wasPlaying = isPlaying
                let sessionID = currentPlaybackSessionID
                
                // FIXED: Update UI on main thread
                DispatchQueue.main.async {
                    self.isPlaying = false
                }
                
                player.scheduleFile(currentFile, at: nil) { [weak self] in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if self.currentPlaybackSessionID == sessionID && wasPlaying {
                            self.next()
                        }
                    }
                }
                
                if wasPlaying {
                    player.play()
                    DispatchQueue.main.async {
                        self.isPlaying = true
                        self.startTimeUpdates()
                    }
                }
                
                print("✅ Engine restarted after configuration change")
            }
        } catch {
            print("❌ Failed to restart engine after configuration change: \(error)")
        }
    }
    
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
            DispatchQueue.main.async {
                self.isPlaying = false
            }
            isEngineRunning = false
        }
        
        DispatchQueue.main.async {
            self.isPlaylistMode = true
            self.currentPlaylist = shuffle ? tracks.shuffled() : tracks
            self.currentIndex = 0
            if !self.currentPlaylist.isEmpty {
                self.play(self.currentPlaylist[0])
            }
        }
    }
    
    func play(_ track: Track) {
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        if isPlaying {
            playerNode?.stop()
            audioEngine?.stop()
            DispatchQueue.main.async {
                self.isPlaying = false
            }
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
            
            let frameCount = Double(file.length)
            let sampleRate = file.fileFormat.sampleRate
            let calculatedDuration = frameCount / sampleRate
            
            DispatchQueue.main.async {
                self.isPlaying = true
                self.currentTrack = track
                
                if let index = self.currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                    self.currentIndex = index
                }
                
                self.duration = calculatedDuration
                self.startTimeUpdates()
                self.updateNowPlayingInfo()
            }
            
            print("▶️ Now playing: \(track.name)")
            
        } catch {
            print("❌ Playback error: \(error)")
        }
    }
    
    func pause() {
        playerNode?.pause()
        DispatchQueue.main.async {
            self.isPlaying = false
            self.stopTimeUpdates()
            self.updateNowPlayingInfo()
        }
    }
    
    func resume() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("❌ Failed to reactivate audio session: \(error)")
        }
        
        ensureEngineRunning()
        
        playerNode?.play()
        DispatchQueue.main.async {
            self.isPlaying = true
            self.startTimeUpdates()
            self.updateNowPlayingInfo()
        }
    }
    
    func stop() {
        playerNode?.stop()
        audioEngine?.stop()
        stopTimeUpdates()
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTrack = nil
            self.currentTime = 0
            self.duration = 0
        }
        isEngineRunning = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    // FIXED: Clamp seek position to valid range
    func seek(to time: Double) {
        guard let file = audioFile,
              let player = playerNode else { return }
        
        // FIXED: Clamp time to valid range [0, duration-1]
        let clampedTime = max(0, min(time, duration - 1))
        
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        let sampleRate = file.fileFormat.sampleRate
        let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
        
        pauseTimeUpdates()
        
        player.stop()
        
        ensureEngineRunning()
        
        // FIXED: Make sure we don't try to play beyond file length
        if startFrame < file.length && startFrame >= 0 {
            let remainingFrames = AVAudioFrameCount(file.length - startFrame)
            
            if remainingFrames > 0 {
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
            } else {
                // FIXED: If no frames left, just go to next song
                DispatchQueue.main.async {
                    self.next()
                }
                return
            }
        } else {
            // FIXED: Seeking beyond file, go to next song
            DispatchQueue.main.async {
                self.next()
            }
            return
        }
        
        self.seekOffset = clampedTime
        
        DispatchQueue.main.async {
            self.currentTime = clampedTime
            self.updateNowPlayingInfo()
        }
        
        resumeTimeUpdates()
    }
    
    // FIXED: Clamp skip to valid range
    func skip(seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration - 1))
        seek(to: newTime)
    }
    
    func setPlaybackRate(_ rate: Float) {
        timePitchNode?.rate = rate
        DispatchQueue.main.async {
            self.isPlaying = (rate != 0)
        }
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
    
    // FIXED: Close now playing view when no more songs
    func next() {
        if isLoopEnabled {
            seek(to: 0)
            return
        }
        
        if isPlaylistMode {
            guard !currentPlaylist.isEmpty else {
                DispatchQueue.main.async {
                    self.stop()
                    self.onPlaybackEnded?()
                }
                return
            }
            currentIndex = (currentIndex + 1) % currentPlaylist.count
            play(currentPlaylist[currentIndex])
        } else {
            if !queue.isEmpty {
                let nextTrack = queue.removeFirst()
                play(nextTrack)
            } else {
                // FIXED: No more songs, stop and close now playing
                DispatchQueue.main.async {
                    self.stop()
                    self.onPlaybackEnded?()
                }
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
        DispatchQueue.main.async {
            self.queue.append(track)
            
            if self.currentTrack == nil {
                self.isPlaylistMode = false
                let firstTrack = self.queue.removeFirst()
                self.play(firstTrack)
            }
        }
    }
    
    func playNext(_ track: Track) {
        DispatchQueue.main.async {
            self.queue.insert(track, at: 0)
            
            if self.currentTrack == nil {
                self.isPlaylistMode = false
                let firstTrack = self.queue.removeFirst()
                self.play(firstTrack)
            }
        }
    }
    
    func removeFromQueue(at offsets: IndexSet) {
        DispatchQueue.main.async {
            self.queue.remove(atOffsets: offsets)
        }
    }
    
    func moveInQueue(from source: IndexSet, to destination: Int) {
        DispatchQueue.main.async {
            self.queue.move(fromOffsets: source, toOffset: destination)
        }
    }
    
    func clearQueue() {
        DispatchQueue.main.async {
            self.queue.removeAll()
        }
    }
    
    func playFromQueue(_ track: Track) {
        if let index = queue.firstIndex(where: { $0.id == track.id }) {
            DispatchQueue.main.async {
                self.queue.remove(at: index)
            }
        }
        
        DispatchQueue.main.async {
            self.isPlaylistMode = false
            self.play(track)
        }
    }
    
    private func startTimeUpdates() {
        stopTimeUpdates()
        
        DispatchQueue.main.async {
            self.displayLink = CADisplayLink(target: self, selector: #selector(self.updateTime))
            self.displayLink?.preferredFramesPerSecond = 2
            self.displayLink?.add(to: .main, forMode: .common)
        }
    }
    
    private func stopTimeUpdates() {
        DispatchQueue.main.async {
            self.displayLink?.invalidate()
            self.displayLink = nil
        }
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
        
        let newTime = seekOffset + currentSegmentTime
        
        // FIXED: Make sure we don't exceed duration
        DispatchQueue.main.async {
            self.currentTime = min(newTime, self.duration)
            
            if Int(self.currentTime) % 5 == 0 {
                self.updateNowPlayingInfo()
            }
        }
    }
    
    deinit {
        stopTimeUpdates()
        NotificationCenter.default.removeObserver(self)
    }
}