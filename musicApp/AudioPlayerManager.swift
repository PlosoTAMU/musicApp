import Foundation
import AVFoundation
import MediaPlayer
import Accelerate

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
    // FIXED: Dedicated high-priority audio thread
    private let audioQueue = DispatchQueue(
        label: "com.musicapp.audioplayback",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    
    var savedPlaybackSpeed: Double = 1.0
    private var currentPlaybackSessionID = UUID()
    
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var reverbNode: AVAudioUnitReverb?
    private var timePitchNode: AVAudioUnitTimePitch?
    
    private var timeUpdateTimer: Timer?
    
    // ✅ SIMPLIFIED: Bass-only visualization (no per-segment data needed)
    @Published var bassLevel: Float = 0
    @Published var pulse: CGFloat = 1.0  // Published pulse for thumbnail + bars scaling
    
    // ✅ ULTRA-SIMPLE: No FFT needed - just RMS energy from low-pass filtered signal
    private let visualizationBufferSize: AVAudioFrameCount = 512  // Small = fast updates (~86 FPS at 44.1kHz)
    private var visualizationTapInstalled = false
    
    // Bass detection state (persists across frames)
    private var smoothedBass: Float = 0
    private var currentPulse: CGFloat = 1.0
    private var previousSamples: [Float] = Array(repeating: 0, count: 64)  // For simple low-pass
    private var smoothedBass: Float = 0

    private func startTimeUpdates() {
        stopTimeUpdates()
        timeUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateTime()
        }
    }

    private func stopTimeUpdates() {
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil
    }
    private var seekOffset: TimeInterval = 0
    
    private var needsReschedule = false
    private var savedCurrentTime: Double = 0
    
    private var isHandlingRouteChange = false
    private var routeChangeTimestamp: Date?
    
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
            
            audioQueue.async {
                self.playerNode?.pause()
            }
            
            DispatchQueue.main.async {
                self.isPlaying = false
                self.stopTimeUpdates()
            }
            
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
    
    @objc private func handleEngineConfigurationChange(notification: Notification) {
        print("⚙️ Audio engine configuration changed")
        
        currentPlaybackSessionID = UUID()
        
        isHandlingRouteChange = true
        routeChangeTimestamp = Date()
        
        let wasPlaying = isPlaying
        savedCurrentTime = currentTime
        needsReschedule = true
        
        audioQueue.async {
            self.playerNode?.stop()
        }
        
        DispatchQueue.main.async {
            self.isPlaying = false
            self.stopTimeUpdates()
        }
        
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
            
            currentPlaybackSessionID = UUID()
            isHandlingRouteChange = true
            routeChangeTimestamp = Date()
            
            savedCurrentTime = currentTime
            needsReschedule = true
            
            audioQueue.async {
                self.playerNode?.stop()
            }
            
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
        audioQueue.async {
            self.playerNode?.stop()
            self.audioEngine?.stop()
            
            DispatchQueue.main.async {
                self.isPlaying = false
                self.isPlaylistMode = true
                self.currentPlaylist = shuffle ? tracks.shuffled() : tracks
                self.currentIndex = 0
                self.previousQueue.removeAll()
                
                if !self.currentPlaylist.isEmpty {
                    self.play(self.currentPlaylist[0])
                }
            }
        }
    }
    
    func play(_ track: Track) {
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.playerNode?.stop()
            self.audioEngine?.stop()
            
            DispatchQueue.main.async {
                self.isPlaying = false
                self.stopTimeUpdates()
                self.seekOffset = 0
                self.needsReschedule = false
                self.isHandlingRouteChange = false
            }
            
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                
                guard let trackURL = track.resolvedURL() else {
                    print("❌ Could not resolve track URL")
                    return
                }
                
                _ = trackURL.startAccessingSecurityScopedResource()
                
                self.currentTrackURL = trackURL
                
                self.audioFile = try AVAudioFile(forReading: trackURL)
                
                guard let file = self.audioFile,
                      let engine = self.audioEngine,
                      let player = self.playerNode,
                      let reverb = self.reverbNode,
                      let timePitch = self.timePitchNode else {
                    print("❌ Audio nodes not configured")
                    return
                }
                
                let format = file.processingFormat
                
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
                    
                    DispatchQueue.main.async {
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

                self.installVisualizationTap()
                
                let frameCount = Double(file.length)
                let sampleRate = file.fileFormat.sampleRate
                let calculatedDuration = frameCount / sampleRate
                
                DispatchQueue.main.async {
                    self.isPlaying = true
                    self.currentTrack = track
                    self.savedCurrentTime = 0
                    self.duration = calculatedDuration
                    
                    if let index = self.currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                        self.currentIndex = index
                    }
                    
                    self.startTimeUpdates()
                    self.updateNowPlayingInfo()
                }
                
                print("▶️ Now playing: \(track.name)")
                
            } catch {
                print("❌ Playback error: \(error)")
            }
        }
    }
    
    func pause() {
        savedCurrentTime = currentTime
        needsReschedule = true
        
        audioQueue.async {
            self.playerNode?.pause()
            
            DispatchQueue.main.async {
                self.isPlaying = false
                self.stopTimeUpdates()
                self.updateNowPlayingInfo()
            }
        }
    }
    
    func resume() {
        guard let track = currentTrack,
              let trackURL = currentTrackURL ?? track.resolvedURL() else {
            print("❌ No track to resume")
            return
        }
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
            } catch {
                print("❌ Failed to activate audio session: \(error)")
            }
            
            guard let engine = self.audioEngine,
                  let player = self.playerNode,
                  let reverb = self.reverbNode,
                  let timePitch = self.timePitchNode else {
                print("❌ Audio components not available")
                return
            }
            
            do {
                _ = trackURL.startAccessingSecurityScopedResource()
                self.audioFile = try AVAudioFile(forReading: trackURL)
            } catch {
                print("❌ Failed to re-open audio file: \(error)")
                return
            }
            
            guard let file = self.audioFile else {
                print("❌ Audio file not available")
                return
            }
            
            let format = file.processingFormat
            
            player.stop()
            engine.stop()
            
            engine.disconnectNodeInput(player)
            engine.disconnectNodeInput(timePitch)
            engine.disconnectNodeInput(reverb)
            
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
            
            do {
                try engine.start()
                print("✅ Engine started with format: \(format)")
            } catch {
                print("❌ Failed to start engine: \(error)")
                return
            }
            
            self.currentPlaybackSessionID = UUID()
            let sessionID = self.currentPlaybackSessionID
            
            let resumeTime = self.needsReschedule ? self.savedCurrentTime : self.currentTime
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
                
                self.seekOffset = resumeTime
                
                DispatchQueue.main.async {
                    self.currentTime = resumeTime
                }
            } else {
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
                self.seekOffset = 0
                DispatchQueue.main.async {
                    self.currentTime = 0
                }
            }
            
            player.play()
            
            // ✅ FIX: Reinstall visualization tap after resume (player.stop() removes it)
            self.installVisualizationTap()
            
            DispatchQueue.main.async {
                self.needsReschedule = false
                self.isPlaying = true
                self.startTimeUpdates()
                self.updateNowPlayingInfo()
            }
            
            print("▶️ Resumed playback")
        }
    }
    
    func stop() {
        currentPlaybackSessionID = UUID()

        removeVisualizationTap()
        
        audioQueue.async {
            self.playerNode?.stop()
            self.audioEngine?.stop()
            
            DispatchQueue.main.async {
                self.stopTimeUpdates()
                self.isPlaying = false
                self.currentTrack = nil
                self.currentTime = 0
                self.duration = 0
                self.needsReschedule = false
                self.savedCurrentTime = 0
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        }
        
        currentTrackURL = nil
    }
    
    func seek(to time: Double) {
        guard let file = audioFile else { return }
        
        let clampedTime = max(0, min(time, duration - 0.5))
        
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        
        DispatchQueue.main.async {
            self.stopTimeUpdates()
        }
        
        audioQueue.async { [weak self] in
            guard let self = self,
                  let player = self.playerNode,
                  let engine = self.audioEngine,
                  let file = self.audioFile else { return }
            
            let sampleRate = file.fileFormat.sampleRate
            let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
            
            player.stop()
            
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
                            if self.currentPlaybackSessionID == sessionID &&
                               !self.isHandlingRouteChange &&
                               self.isPlaying {
                                self.next()
                            }
                        }
                    }
                    
                    if self.isPlaying {
                        player.play()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.next()
                    }
                    return
                }
            }
            
            self.seekOffset = clampedTime
            
            DispatchQueue.main.async {
                self.currentTime = clampedTime
                self.savedCurrentTime = clampedTime
                self.updateNowPlayingInfo()
                
                if self.isPlaying {
                    self.startTimeUpdates()
                }
            }
        }
    }
    
    func skip(seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration - 0.5))
        seek(to: newTime)
    }
    
    private func applyReverb() {
        audioQueue.async {
            self.reverbNode?.wetDryMix = Float(self.reverbAmount)
        }
    }
    
    private func applyPlaybackSpeed() {
        audioQueue.async {
            guard let timePitch = self.timePitchNode else { return }
            
            let speed = Float(self.playbackSpeed)
            
            if self.playbackSpeed < 1.0 {
                timePitch.rate = speed
                timePitch.pitch = 0
                timePitch.overlap = 8.0
            } else {
                timePitch.rate = speed
                timePitch.pitch = 0
                timePitch.overlap = 8.0
            }
            
            if self.playbackSpeed != 2.0 {
                self.savedPlaybackSpeed = self.playbackSpeed
            }
            
            DispatchQueue.main.async {
                self.updateNowPlayingInfo()
            }
            
            print("⚡ Playback speed set to: \(self.playbackSpeed)x")
        }
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

    // MARK: - Bass-Only Visualization (Ultra-Simple, Zero Latency)

    private func installVisualizationTap() {
        guard let player = playerNode else { return }
        
        // Remove existing tap if any
        if visualizationTapInstalled {
            player.removeTap(onBus: 0)
            visualizationTapInstalled = false
        }
        
        let format = player.outputFormat(forBus: 0)
        
        // Small buffer = high update rate = responsive visualization
        player.installTap(onBus: 0, bufferSize: visualizationBufferSize, format: format) { [weak self] buffer, _ in
            self?.processBassFromBuffer(buffer)
        }
        
        visualizationTapInstalled = true
        print("✅ [AudioPlayer] Bass visualization tap installed")
    }

    private func removeVisualizationTap() {
        guard visualizationTapInstalled else { return }
        playerNode?.removeTap(onBus: 0)
        visualizationTapInstalled = false
        print("✅ [AudioPlayer] Visualization tap removed")
    }

    /// Ultra-fast bass extraction - no FFT, just simple energy detection
    private func processBassFromBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = channelData[0]
        
        // ==========================================
        // ULTRA-SIMPLE BASS DETECTION (NO FFT!)
        // ==========================================
        // Use a simple low-pass filter approach:
        // Bass frequencies cause slow, large amplitude changes
        // We detect this by measuring RMS energy of downsampled signal
        
        // Step 1: Downsample by taking every 8th sample (reduces 512 -> 64)
        // This naturally low-pass filters to ~2.75kHz at 44.1kHz sample rate
        // Bass is < 250Hz so we're capturing it
        var bassEnergy: Float = 0
        let downsampleFactor = 8
        let downsampledCount = frameLength / downsampleFactor
        
        for i in 0..<downsampledCount {
            let sample = samples[i * downsampleFactor]
            // Accumulate squared amplitude (RMS)
            bassEnergy += sample * sample
        }
        
        // Normalize to 0-1 range (RMS)
        bassEnergy = sqrt(bassEnergy / Float(max(1, downsampledCount)))
        
        // Amplify to useful range (audio is often quiet)
        bassEnergy = min(1.0, bassEnergy * 4.0)
        
        // ==========================================
        // PULSE CALCULATION (matches HTML logic)
        // ==========================================
        let bassThreshold: Float = 0.08
        let bassMultiplier: Float = 0.5
        let pulseSmooth: Float = 0.35  // Faster response than before
        
        // Smooth the bass energy
        smoothedBass = smoothedBass * 0.6 + bassEnergy * 0.4
        
        // Calculate pulse
        let bassPulse: Float = smoothedBass > bassThreshold 
            ? (smoothedBass - bassThreshold) / (1.0 - bassThreshold) 
            : 0
        let targetPulse: CGFloat = 1.0 + CGFloat(bassPulse) * CGFloat(bassMultiplier)
        currentPulse += (targetPulse - currentPulse) * CGFloat(pulseSmooth)
        
        // ==========================================
        // PUBLISH TO MAIN THREAD (minimal data)
        // ==========================================
        let finalPulse = currentPulse
        let finalBass = smoothedBass
        
        DispatchQueue.main.async { [weak self] in
            self?.pulse = finalPulse
            self?.bassLevel = finalBass
        }
    }
}

