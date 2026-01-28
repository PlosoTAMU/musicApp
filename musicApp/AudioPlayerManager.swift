import Foundation
import AVFoundation
import MediaPlayer

class AudioPlayerManager: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTrack: Track?
    @Published var currentPlaylist: [Track] = []
    @Published var queue: [Track] = []
    @Published var previousQueue: [Track] = []
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
    
    private var displayLink: CADisplayLink?
    private var seekOffset: TimeInterval = 0
    
    private var needsReschedule = false
    private var savedCurrentTime: Double = 0
    
    // CRITICAL FIX: Track route changes to prevent false completion triggers
    private var isHandlingRouteChange = false
    private var routeChangeTimestamp: Date?
    
    // Store current track URL for re-opening after route change
    private var currentTrackURL: URL?
    
    var onPlaybackEnded: (() -> Void)?
    
    override init() {
        super.init()
        setupAudioSession()
        setupAudioEngine()
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
        timePitch.rate = 1.0
        
        print("✅ Audio engine configured")
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
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
        
        // CRITICAL: Listen for engine configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: nil
        )
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
            savedCurrentTime = currentTime
            needsReschedule = true
            isHandlingRouteChange = true
            
            DispatchQueue.main.async {
                self.isPlaying = false
            }
            playerNode?.pause()
            stopTimeUpdates()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.isHandlingRouteChange = false
            }
            
        case .ended:
            print("🎧 Audio interruption ended")
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.resume()
                }
            }
        @unknown default:
            break
        }
    }
    
    // CRITICAL FIX: Handle engine configuration changes (Bluetooth connect/disconnect)
    @objc private func handleEngineConfigurationChange(notification: Notification) {
        print("⚙️ Audio engine configuration changed")
        
        // CRITICAL: Invalidate session ID to prevent completion handler from calling next()
        currentPlaybackSessionID = UUID()
        
        isHandlingRouteChange = true
        routeChangeTimestamp = Date()
        
        let wasPlaying = isPlaying
        savedCurrentTime = currentTime
        needsReschedule = true
        
        // Stop player but don't trigger next()
        playerNode?.stop()
        
        DispatchQueue.main.async {
            self.isPlaying = false
            self.stopTimeUpdates()
        }
        
        // Give system time to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.isHandlingRouteChange = false
            
            if wasPlaying {
                print("ℹ️ Audio was playing before config change. Ready to resume.")
            }
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
            print("🎧 Audio device disconnected (Bluetooth/headphones)")
            
            // CRITICAL: Invalidate session ID immediately
            currentPlaybackSessionID = UUID()
            isHandlingRouteChange = true
            routeChangeTimestamp = Date()
            
            savedCurrentTime = currentTime
            needsReschedule = true
            
            playerNode?.stop()
            
            DispatchQueue.main.async {
                self.isPlaying = false
                self.stopTimeUpdates()
                self.updateNowPlayingInfo()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.isHandlingRouteChange = false
            }
            
        case .newDeviceAvailable:
            print("🎧 New audio device connected")
            
            // CRITICAL: Invalidate session ID to prevent false completion
            currentPlaybackSessionID = UUID()
            isHandlingRouteChange = true
            routeChangeTimestamp = Date()
            
            savedCurrentTime = currentTime
            needsReschedule = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.isHandlingRouteChange = false
            }
            
        case .categoryChange:
            print("🎧 Audio category changed")
            
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
        if isPlaying {
            playerNode?.stop()
            audioEngine?.stop()
            isPlaying = false
        }
        
        isPlaylistMode = true
        currentPlaylist = shuffle ? tracks.shuffled() : tracks
        currentIndex = 0
        previousQueue.removeAll()
        
        if !currentPlaylist.isEmpty {
            play(currentPlaylist[0])
        }
    }
    
    func play(_ track: Track) {
        // CRITICAL: Create new session ID to invalidate any old completion handlers
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        if isPlaying {
            playerNode?.stop()
            audioEngine?.stop()
            isPlaying = false
        }
        
        stopTimeUpdates()
        seekOffset = 0
        needsReschedule = false
        isHandlingRouteChange = false
        
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            
            guard let trackURL = track.resolvedURL() else {
                print("❌ Could not resolve track URL")
                return
            }
            
            _ = trackURL.startAccessingSecurityScopedResource()
            
            // Store URL for potential re-open after route change
            currentTrackURL = trackURL
            
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
            
            // Disconnect and reconnect to handle format changes
            engine.disconnectNodeInput(player)
            engine.disconnectNodeInput(timePitch)
            engine.disconnectNodeInput(reverb)
            
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
            
            if !engine.isRunning {
                try engine.start()
            }
            
            player.scheduleFile(file, at: nil) { [weak self] in
                guard let self = self else { return }
                
                // CRITICAL: Check BOTH session ID AND route change flag
                DispatchQueue.main.async {
                    // Only call next() if:
                    // 1. Session ID matches (no new track started)
                    // 2. Not handling a route change
                    // 3. Actually playing
                    if self.currentPlaybackSessionID == sessionID &&
                       !self.isHandlingRouteChange &&
                       self.isPlaying {
                        self.next()
                    } else {
                        print("⚠️ Completion handler ignored (sessionID: \(sessionID == self.currentPlaybackSessionID), routeChange: \(self.isHandlingRouteChange), playing: \(self.isPlaying))")
                    }
                }
            }
            
            player.play()
            
            isPlaying = true
            currentTrack = track
            savedCurrentTime = 0
            
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
        savedCurrentTime = currentTime
        needsReschedule = true
        
        playerNode?.pause()
        isPlaying = false
        stopTimeUpdates()
        updateNowPlayingInfo()
    }
    
    // CRITICAL FIX: Complete rewrite of resume() to handle Bluetooth properly
    func resume() {
        guard let track = currentTrack,
              let trackURL = currentTrackURL ?? track.resolvedURL() else {
            print("❌ No track to resume")
            return
        }
        
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("❌ Failed to activate audio session: \(error)")
        }
        
        guard let engine = audioEngine,
              let player = playerNode,
              let reverb = reverbNode,
              let timePitch = timePitchNode else {
            print("❌ Audio components not available")
            return
        }
        
        // CRITICAL: Always re-open the audio file after route change
        // This handles sample rate changes from Bluetooth
        do {
            _ = trackURL.startAccessingSecurityScopedResource()
            audioFile = try AVAudioFile(forReading: trackURL)
        } catch {
            print("❌ Failed to re-open audio file: \(error)")
            return
        }
        
        guard let file = audioFile else {
            print("❌ Audio file not available")
            return
        }
        
        let format = file.processingFormat
        
        // CRITICAL: Stop player and engine completely
        player.stop()
        engine.stop()
        
        // Reconnect with potentially new format
        engine.disconnectNodeInput(player)
        engine.disconnectNodeInput(timePitch)
        engine.disconnectNodeInput(reverb)
        
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        
        // Start engine
        do {
            try engine.start()
            print("✅ Engine started with format: \(format)")
        } catch {
            print("❌ Failed to start engine: \(error)")
            return
        }
        
        // Create new session ID
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        // Calculate start position
        let resumeTime = needsReschedule ? savedCurrentTime : currentTime
        let sampleRate = file.fileFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, resumeTime) * sampleRate)
        
        print("🔄 Resuming from \(resumeTime)s (frame: \(startFrame))")
        
        if startFrame < file.length && startFrame >= 0 {
            let remainingFrames = AVAudioFrameCount(file.length - startFrame)
            
            player.scheduleSegment(file,
                                  startingFrame: startFrame,
                                  frameCount: remainingFrames,
                                  at: nil) { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if self.currentPlaybackSessionID == sessionID &&
                       !self.isHandlingRouteChange &&
                       self.isPlaying {
                        self.next()
                    }
                }
            }
            
            seekOffset = resumeTime
            currentTime = resumeTime
        } else {
            // Start from beginning if position is invalid
            player.scheduleFile(file, at: nil) { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if self.currentPlaybackSessionID == sessionID &&
                       !self.isHandlingRouteChange &&
                       self.isPlaying {
                        self.next()
                    }
                }
            }
            seekOffset = 0
            currentTime = 0
        }
        
        player.play()
        
        needsReschedule = false
        isPlaying = true
        startTimeUpdates()
        updateNowPlayingInfo()
        
        print("▶️ Resumed playback")
    }
    
    func stop() {
        // Invalidate session to prevent any pending completion handlers
        currentPlaybackSessionID = UUID()
        
        playerNode?.stop()
        audioEngine?.stop()
        stopTimeUpdates()
        
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTrack = nil
            self.currentTime = 0
            self.duration = 0
            self.needsReschedule = false
            self.savedCurrentTime = 0
        }
        
        currentTrackURL = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    func seek(to time: Double) {
        guard let file = audioFile,
              let player = playerNode,
              let engine = audioEngine else { return }
        
        // Clamp to valid range
        let clampedTime = max(0, min(time, duration - 0.5))
        
        // Invalidate old session
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        let sampleRate = file.fileFormat.sampleRate
        let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
        
        stopTimeUpdates()
        player.stop()
        
        // Ensure engine is running
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("❌ Failed to start engine for seek: \(error)")
                return
            }
        }
        
        if startFrame < file.length && startFrame >= 0 {
            let remainingFrames = AVAudioFrameCount(file.length - startFrame)
            
            if remainingFrames > 0 {
                player.scheduleSegment(file,
                                      startingFrame: startFrame,
                                      frameCount: remainingFrames,
                                      at: nil) { [weak self] in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        // CRITICAL: Check all conditions before calling next()
                        if self.currentPlaybackSessionID == sessionID &&
                           !self.isHandlingRouteChange &&
                           self.isPlaying {
                            self.next()
                        }
                    }
                }
                
                if isPlaying {
                    player.play()
                }
            } else {
                DispatchQueue.main.async {
                    self.next()
                }
                return
            }
        }
        
        seekOffset = clampedTime
        currentTime = clampedTime
        savedCurrentTime = clampedTime
        updateNowPlayingInfo()
        
        if isPlaying {
            startTimeUpdates()
        }
    }
    
    func skip(seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration - 0.5))
        seek(to: newTime)
    }
    
    private func applyReverb() {
        reverbNode?.wetDryMix = Float(reverbAmount)
    }
    
    private func applyPlaybackSpeed() {
        timePitchNode?.rate = Float(playbackSpeed)
        if playbackSpeed != 2.0 {
            savedPlaybackSpeed = playbackSpeed
        }
        updateNowPlayingInfo()
    }
    
    func previous() {
        if isPlaylistMode {
            guard !currentPlaylist.isEmpty else { return }
            currentIndex = (currentIndex - 1 + currentPlaylist.count) % currentPlaylist.count
            play(currentPlaylist[currentIndex])
        } else {
            if !previousQueue.isEmpty {
                if let current = currentTrack {
                    queue.insert(current, at: 0)
                }
                let previousTrack = previousQueue.removeLast()
                play(previousTrack)
            } else {
                seek(to: 0)
            }
        }
    }
    
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
            if let current = currentTrack {
                previousQueue.append(current)
            }
            
            if !queue.isEmpty {
                let nextTrack = queue.removeFirst()
                play(nextTrack)
            } else {
                DispatchQueue.main.async {
                    self.stop()
                    self.onPlaybackEnded?()
                }
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
            self.previousQueue.removeAll()
        }
    }
    
    func playFromQueue(_ track: Track) {
        if let current = currentTrack {
            previousQueue.append(current)
        }
        
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
        
        let newTime = seekOffset + currentSegmentTime
        
        currentTime = min(newTime, duration)
        
        if Int(currentTime) % 5 == 0 {
            updateNowPlayingInfo()
        }
    }
    
    deinit {
        stopTimeUpdates()
        NotificationCenter.default.removeObserver(self)
    }
}