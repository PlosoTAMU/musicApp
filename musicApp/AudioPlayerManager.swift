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
        didSet { 
            applyReverb()
            saveCurrentTrackSettings() // ✅ SAVE when changed
        }
    }
    @Published var playbackSpeed: Double = 1.0 {
        didSet { 
            applyPlaybackSpeed()
            saveCurrentTrackSettings() // ✅ SAVE when changed
        }
    }
    @Published var pitchShift: Double = 0 {
        didSet {
            applyPitch()
            saveCurrentTrackSettings()
        }
    }
    @Published var bassBoost: Double = 0 {
        didSet {
            applyBassBoost()
            saveCurrentTrackSettings()
        }
    }
    
    @Published var effectsBypass: Bool = false {
        didSet {
            // Re-apply all effects with bypass state
            applyReverb()
            applyBassBoost()
            applyPitch()
            applyPlaybackSpeed()
        }
    }
    
    // ✅ NEW: Store settings per track
    private var trackSettings: [UUID: TrackSettings] = [:]
    private let trackSettingsFileURL: URL
    
    // FIXED: Dedicated high-priority audio thread
    private let audioQueue = DispatchQueue(
        label: "com.musicapp.audioplayback",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    
    var savedPlaybackSpeed: Double = 1.0
    private var currentPlaybackSessionID = UUID()
    private var hasTriggeredNext = false  // ✅ Prevent double-next
    
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var reverbNode: AVAudioUnitReverb?
    private var timePitchNode: AVAudioUnitTimePitch?
    private var eqNode: AVAudioUnitEQ?
    // Premium audio: secondary reverb for depth
    private var reverbNode2: AVAudioUnitReverb?
    
    private var timeUpdateTimer: Timer?
    
    // ✅ Visualization data - @Published with throttling to limit SwiftUI updates
    @Published var bassLevel: Float = 0
    @Published var frequencyBins: [Float] = Array(repeating: 0, count: 100)
    
    // Shuffled indices for randomized bar order (so frequencies are spread out)
    private lazy var shuffledIndices: [Int] = {
        var indices = Array(0..<100)
        indices.shuffle()
        return indices
    }()
    
    // Throttle visualization updates to ~60fps for smoother animation
    private var lastVisualizationUpdate: CFAbsoluteTime = 0
    private let visualizationUpdateInterval: CFAbsoluteTime = 1.0 / 60.0  // 60fps
    
    // FFT setup - use 2048 for better frequency resolution (especially for beat detection)
    private var fftSetup: FFTSetup?
    private let fftSize = 2048
    private let fftSizeHalf = 1024
    private let visualizationBufferSize: AVAudioFrameCount = 2048
    private var visualizationTapInstalled = false
    private var visualizationTapOnMixer = false  // ✅ NEW: Track which node has the tap
    
    // Pre-allocated FFT buffers
    private var fftInputBuffer = [Float](repeating: 0, count: 2048)
    private var fftReal = [Float](repeating: 0, count: 1024)
    private var fftImag = [Float](repeating: 0, count: 1024)
    private var fftMagnitudes = [Float](repeating: 0, count: 1024)
    private var fftLog2n: vDSP_Length = 0
    
    // Smoothed values for display
    private var smoothedBins = [Float](repeating: 0, count: 100)
    private var smoothedBass: Float = 0
    
    // ==========================================
    // ADVANCED BEAT DETECTION SYSTEM
    // ==========================================
    
    // Previous frame's magnitudes for spectral flux calculation
    private var previousMagnitudes = [Float](repeating: 0, count: 1024)
    
    // Energy history for beat detection (circular buffer)
    private var energyHistory = [Float](repeating: 0, count: 43)  // ~1 second at 43 callbacks/sec
    private var energyHistoryIndex = 0
    
    // Spectral flux history for onset detection
    private var fluxHistory = [Float](repeating: 0, count: 43)
    private var fluxHistoryIndex = 0
    
    // Sub-band energy tracking (for different frequency ranges)
    private var subBassHistory = [Float](repeating: 0, count: 20)   // 20-60Hz (kick drum)
    private var bassHistory = [Float](repeating: 0, count: 20)       // 60-250Hz (bass)
    private var lowMidHistory = [Float](repeating: 0, count: 20)     // 250-500Hz (low mids)
    private var subBassHistoryIndex = 0
    
    // Beat state
    private var beatIntensity: Float = 0      // Current beat strength (0-1)
    private var lastBeatTime: CFAbsoluteTime = 0
    private var beatDecayRate: Float = 0.82   // How fast beat pulse decays (punchier = faster decay)
    
    // Adaptive thresholds (auto-adjust to song dynamics)
    private var adaptiveThreshold: Float = 0.5
    private var peakEnergy: Float = 0.01
    private var avgEnergy: Float = 0.01
    
    // Running statistics for normalization
    private var runningMax: Float = 0.001
    private var runningAvg: Float = 0.001
    private var sampleCount: Int = 0

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
        // Setup track settings file URL
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        trackSettingsFileURL = documentsPath.appendingPathComponent("track_settings.json")
        
        super.init()
        
        loadTrackSettings() // ✅ LOAD saved settings
        setupAudioSession()
        setupAudioEngine()
        setupRemoteControls()
        setupInterruptionHandling()
    }
    
    // ✅ NEW: Track settings structure
    private struct TrackSettings: Codable {
        var playbackSpeed: Double
        var reverbAmount: Double
        var pitchShift: Double?
        var bassBoost: Double?
    }
    
    // ✅ NEW: Load saved settings
    private func loadTrackSettings() {
        guard FileManager.default.fileExists(atPath: trackSettingsFileURL.path) else {
            print("ℹ️ [AudioPlayer] No saved track settings")
            return
        }
        
        do {
            let data = try Data(contentsOf: trackSettingsFileURL)
            trackSettings = try JSONDecoder().decode([UUID: TrackSettings].self, from: data)
            print("✅ [AudioPlayer] Loaded settings for \(trackSettings.count) tracks")
        } catch {
            print("❌ [AudioPlayer] Failed to load track settings: \(error)")
        }
    }
    
    // ✅ NEW: Save settings for current track
    private func saveCurrentTrackSettings() {
        guard let trackID = currentTrack?.id else { return }
        
        trackSettings[trackID] = TrackSettings(
            playbackSpeed: playbackSpeed,
            reverbAmount: reverbAmount,
            pitchShift: pitchShift,
            bassBoost: bassBoost
        )
        
        // Save to disk (debounced to avoid excessive writes)
        saveTrackSettingsToDisk()
    }
    
    // ✅ NEW: Write settings to disk
    private func saveTrackSettingsToDisk() {
        do {
            let data = try JSONEncoder().encode(trackSettings)
            try data.write(to: trackSettingsFileURL, options: .atomic)
            print("💾 [AudioPlayer] Saved settings for \(trackSettings.count) tracks")
        } catch {
            print("❌ [AudioPlayer] Failed to save track settings: \(error)")
        }
    }
    
    // ✅ NEW: Apply saved settings for track (or use defaults)
    private func applyTrackSettings(for track: Track) {
        if let settings = trackSettings[track.id] {
            // Restore saved settings
            print("📼 [AudioPlayer] Restoring settings: \(settings.playbackSpeed)x speed, \(settings.reverbAmount)% reverb, \(settings.pitchShift ?? 0) pitch, \(settings.bassBoost ?? 0)dB bass")
            playbackSpeed = settings.playbackSpeed
            reverbAmount = settings.reverbAmount
            pitchShift = settings.pitchShift ?? 0
            bassBoost = settings.bassBoost ?? 0
        } else {
            // Use defaults for new track
            print("📼 [AudioPlayer] Using default settings: 1.0x speed, 0% reverb, 0 pitch, 0dB bass")
            playbackSpeed = 1.0
            reverbAmount = 0.0
            pitchShift = 0
            bassBoost = 0
        }
    }

    
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        timePitchNode = AVAudioUnitTimePitch()
        
        // ── Premium EQ: 5-band parametric for surgical bass shaping ──
        // Band 0: Sub-bass shelf   (40Hz)  — the chest-thump frequencies
        // Band 1: Mid-bass bell    (120Hz) — warmth and body
        // Band 2: Mud cut          (300Hz) — always slightly scooped to keep clarity
        // Band 3: Presence shelf   (3kHz)  — compensate treble when bass is boosted
        // Band 4: Air shelf        (10kHz) — sparkle to offset any muddiness
        eqNode = AVAudioUnitEQ(numberOfBands: 5)
        
        // ── Premium Reverb: dual-stage (early reflections + tail) ──
        reverbNode = AVAudioUnitReverb()   // Primary: small room for early reflections / intimacy
        reverbNode2 = AVAudioUnitReverb()  // Secondary: large space for the tail
        
        guard let engine = audioEngine,
              let player = playerNode,
              let timePitch = timePitchNode,
              let eq = eqNode,
              let reverb1 = reverbNode,
              let reverb2 = reverbNode2 else { return }
        
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(eq)
        engine.attach(reverb1)
        engine.attach(reverb2)
        
        // ── TimePitch: premium quality settings ──
        timePitch.rate = 1.0
        timePitch.pitch = 0
        timePitch.overlap = 32  // Maximum overlap for cleanest time-stretching (less artifacts)
        
        // ── EQ Bands ──
        let subBass = eq.bands[0]
        subBass.filterType = .lowShelf
        subBass.frequency = 40
        subBass.bandwidth = 0.8
        subBass.gain = 0
        subBass.bypass = false
        
        let midBass = eq.bands[1]
        midBass.filterType = .parametric
        midBass.frequency = 120
        midBass.bandwidth = 1.2  // Moderate Q for musical width
        midBass.gain = 0
        midBass.bypass = false
        
        let mudCut = eq.bands[2]
        mudCut.filterType = .parametric
        mudCut.frequency = 300
        mudCut.bandwidth = 1.5
        mudCut.gain = 0   // Will be auto-scooped proportional to bass boost
        mudCut.bypass = false
        
        let presence = eq.bands[3]
        presence.filterType = .parametric
        presence.frequency = 3000
        presence.bandwidth = 1.0
        presence.gain = 0   // Will add a touch of presence when bass is up
        presence.bypass = false
        
        let air = eq.bands[4]
        air.filterType = .highShelf
        air.frequency = 10000
        air.bandwidth = 0.7
        air.gain = 0
        air.bypass = false
        
        // ── Reverb 1: medium hall for natural musical reverb ──
        reverb1.loadFactoryPreset(.mediumHall)
        reverb1.wetDryMix = 0
        
        // ── Reverb 2: plate for silky tail (less harsh than cathedral) ──
        reverb2.loadFactoryPreset(.plate)
        reverb2.wetDryMix = 0
        
        print("✅ Premium audio engine configured (5-band EQ, dual-reverb, high-overlap pitch)")
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
            
                // ✅ AUTO-DISABLE: Disable loop when loading a playlist
                if self.isLoopEnabled {
                    self.isLoopEnabled = false
                    print("🔁 [AudioPlayer] Loop disabled - playlist loaded")
                }
                
                if !self.currentPlaylist.isEmpty {
                    self.play(self.currentPlaylist[0])
                }
            }
        }
    }
    
    func play(_ track: Track) {
        PerformanceMonitor.shared.start("AudioPlayer_Play") // ✅ ADDED
        defer { PerformanceMonitor.shared.end("AudioPlayer_Play") } // ✅ ADDED
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        hasTriggeredNext = false  // ✅ RESET: New track, allow next() to be triggered again
    
        // ✅ FIX: Reset visualization IMMEDIATELY and SYNCHRONOUSLY
        // This ensures UI shows zero before any async work happens
        if Thread.isMainThread {
            self.frequencyBins = [Float](repeating: 0, count: 100)
            self.bassLevel = 0
        } else {
            DispatchQueue.main.sync {
                self.frequencyBins = [Float](repeating: 0, count: 100)
                self.bassLevel = 0
            }
        }
        
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
                      let reverb1 = self.reverbNode,
                      let reverb2 = self.reverbNode2,
                      let timePitch = self.timePitchNode,
                      let eq = self.eqNode else {
                    print("❌ Audio nodes not configured")
                    return
                }
                
                let format = file.processingFormat
                
                engine.disconnectNodeInput(player)
                engine.disconnectNodeInput(timePitch)
                engine.disconnectNodeInput(eq)
                engine.disconnectNodeInput(reverb1)
                engine.disconnectNodeInput(reverb2)
                
                // Chain: player → timePitch → EQ → reverb1 (early) → reverb2 (tail) → mixer
                engine.connect(player, to: timePitch, format: format)
                engine.connect(timePitch, to: eq, format: format)
                engine.connect(eq, to: reverb1, format: format)
                engine.connect(reverb1, to: reverb2, format: format)
                engine.connect(reverb2, to: engine.mainMixerNode, format: format)
                
                if !engine.isRunning {
                    try engine.start()
                }
                
                // ✅ FIX: Schedule the entire file + add 0.5s silence buffer to ensure we reach the full duration
                let sampleRate = file.fileFormat.sampleRate
                let paddingFrames = AVAudioFrameCount(0.5 * sampleRate) // 0.5 seconds of silence
                
                // Schedule the actual file content
                player.scheduleSegment(file,
                                      startingFrame: 0,
                                      frameCount: AVAudioFrameCount(file.length),
                                      at: nil)
                
                // Schedule silence padding after the file
                let silenceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                     frameCapacity: paddingFrames)!
                silenceBuffer.frameLength = paddingFrames
                // Buffer is already zeroed (silence)
                
                player.scheduleBuffer(silenceBuffer, at: nil) { [weak self] in
                    guard let self = self else { return }
                    
                    DispatchQueue.main.async {
                        if self.currentPlaybackSessionID == sessionID &&
                           !self.isHandlingRouteChange &&
                           self.isPlaying &&
                           !self.hasTriggeredNext {
                            self.hasTriggeredNext = true
                            self.next()
                        }
                    }
                }
                
                player.play()

                // ✅ FIX: Move visualizer setup OFF critical path
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.resetBeatDetectionState()
                    self?.installVisualizationTap()
                }
                
                // ✅ Calculate duration from file.length (playback will now exceed this slightly)
                let frameCount = Double(file.length)
                let calculatedDuration = frameCount / sampleRate
                
                DispatchQueue.main.async {
                    self.isPlaying = true
                    self.currentTrack = track
                    self.savedCurrentTime = 0
                    self.duration = calculatedDuration
                    
                    if let index = self.currentPlaylist.firstIndex(where: { $0.id == track.id }) {
                        self.currentIndex = index
                    }
                    
                    // ✅ Apply saved settings AFTER audio engine is ready
                    self.applyTrackSettings(for: track)
                    
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
                  let reverb1 = self.reverbNode,
                  let reverb2 = self.reverbNode2,
                  let timePitch = self.timePitchNode,
                  let eq = self.eqNode else {
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
            engine.disconnectNodeInput(eq)
            engine.disconnectNodeInput(reverb1)
            engine.disconnectNodeInput(reverb2)
            
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: eq, format: format)
            engine.connect(eq, to: reverb1, format: format)
            engine.connect(reverb1, to: reverb2, format: format)
            engine.connect(reverb2, to: engine.mainMixerNode, format: format)
            
            do {
                try engine.start()
                print("✅ Engine started with format: \(format)")
            } catch {
                print("❌ Failed to start engine: \(error)")
                return
            }
            
            self.currentPlaybackSessionID = UUID()
            let sessionID = self.currentPlaybackSessionID
            self.hasTriggeredNext = false  // ✅ RESET: Resuming playback, allow next() to be triggered again
            
            let resumeTime = self.needsReschedule ? self.savedCurrentTime : self.currentTime
            let sampleRate = file.fileFormat.sampleRate
            let startFrame = AVAudioFramePosition(max(0, resumeTime) * sampleRate)
            
            print("🔄 Resuming from \(resumeTime)s (frame: \(startFrame))")
            
            if startFrame < file.length && startFrame >= 0 {
                let remainingFrames = AVAudioFrameCount(file.length - startFrame)
                let sampleRate = file.fileFormat.sampleRate
                let paddingFrames = AVAudioFrameCount(0.5 * sampleRate)
                
                // Schedule remaining audio
                player.scheduleSegment(file,
                                      startingFrame: startFrame,
                                      frameCount: remainingFrames,
                                      at: nil)
                
                // Schedule silence padding after
                let silenceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                     frameCapacity: paddingFrames)!
                silenceBuffer.frameLength = paddingFrames
                
                player.scheduleBuffer(silenceBuffer, at: nil) { [weak self] in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if self.currentPlaybackSessionID == sessionID &&
                           !self.isHandlingRouteChange &&
                           self.isPlaying &&
                           !self.hasTriggeredNext {
                            self.hasTriggeredNext = true
                            self.next()
                        }
                    }
                }
                
                self.seekOffset = resumeTime
                
                DispatchQueue.main.async {
                    self.currentTime = resumeTime
                }
            } else {
                // ✅ FIX: Schedule entire file + silence padding
                let sampleRate = file.fileFormat.sampleRate
                let paddingFrames = AVAudioFrameCount(0.5 * sampleRate)
                
                player.scheduleSegment(file,
                                      startingFrame: 0,
                                      frameCount: AVAudioFrameCount(file.length),
                                      at: nil)
                
                let silenceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                     frameCapacity: paddingFrames)!
                silenceBuffer.frameLength = paddingFrames
                
                player.scheduleBuffer(silenceBuffer, at: nil) { [weak self] in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if self.currentPlaybackSessionID == sessionID &&
                           !self.isHandlingRouteChange &&
                           self.isPlaying &&
                           !self.hasTriggeredNext {
                            self.hasTriggeredNext = true
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
            self.resetBeatDetectionState()
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
    
    // Update the current track URL (used when file is renamed while playing)
    func updateCurrentTrackURL(_ newURL: URL) {
        currentTrackURL = newURL
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
        hasTriggeredNext = false  // ✅ RESET: Seeking means we're not at the end anymore
        
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
                    let paddingFrames = AVAudioFrameCount(0.5 * sampleRate)
                    
                    // Schedule remaining audio
                    player.scheduleSegment(file,
                                          startingFrame: startFrame,
                                          frameCount: remainingFrames,
                                          at: nil)
                    
                    // Schedule silence padding after
                    let silenceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                         frameCapacity: paddingFrames)!
                    silenceBuffer.frameLength = paddingFrames
                    
                    player.scheduleBuffer(silenceBuffer, at: nil) { [weak self] in
                        guard let self = self else { return }
                        DispatchQueue.main.async {
                            if self.currentPlaybackSessionID == sessionID &&
                               !self.isHandlingRouteChange &&
                               self.isPlaying &&
                               !self.hasTriggeredNext {
                                self.hasTriggeredNext = true
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
            guard let reverb1 = self.reverbNode,
                  let reverb2 = self.reverbNode2 else { return }
            
            // If bypassed, zero out the reverb
            if self.effectsBypass {
                reverb1.wetDryMix = 0
                reverb2.wetDryMix = 0
                return
            }
            
            let amount = self.reverbAmount  // 0-100
            
            // ── Dual-stage reverb ──
            // Stage 1 (medium hall): natural room sound — the main reverb body.
            //   Gentle curve so low values give a subtle "space" without sounding wet.
            // Stage 2 (plate): silky shimmering tail.
            //   Only blends in at higher values for lush depth.
            //
            // The key to sounding premium: keep wet/dry LOW. Real studio reverb
            // rarely exceeds 25-30% wet. We scale so 50% on the slider ≈ 15% wet
            // (studio-quality territory) and 100% ≈ 40% wet (lush but not washy).
            
            if amount <= 0 {
                reverb1.wetDryMix = 0
                reverb2.wetDryMix = 0
            } else {
                // Main hall reverb: sqrt curve so it ramps gently
                // 10% slider → ~5% wet, 50% slider → ~16% wet, 100% slider → ~32% wet
                let normalized = amount / 100.0
                let hallMix = Float(sqrt(normalized) * 32)
                reverb1.wetDryMix = hallMix
                
                // Plate tail: only fades in above 25% on the slider
                // Adds shimmer/depth on top of the hall, but stays subtle
                // 25% slider → 0%, 50% slider → ~4% wet, 100% slider → ~18% wet
                let tailNormalized = max(0, (amount - 25) / 75.0)
                let plateMix = Float(tailNormalized * tailNormalized * 18)
                reverb2.wetDryMix = plateMix
            }
            
            print("🌊 Reverb: hall=\(reverb1.wetDryMix)%, plate=\(reverb2.wetDryMix)% (user: \(amount)%)")
        }
    }
    
    private func applyPlaybackSpeed() {
        let previousSpeed = savedPlaybackSpeed
        
        audioQueue.async {
            guard let timePitch = self.timePitchNode else { return }
            
            // Speed always applies even when bypassed (it's more like transport control)
            // But pitch is zeroed when bypassed
            let speed = Float(self.playbackSpeed)
            let pitch = self.effectsBypass ? 0 : Float(self.pitchShift * 100)
            
            timePitch.rate = speed
            timePitch.pitch = pitch
            
            // ── Premium time-stretch quality ──
            // Higher overlap = cleaner stretching with fewer phase artifacts.
            // Scale dynamically: extreme speeds need even more overlap to stay clean.
            let deviation = abs(speed - 1.0)
            if deviation > 0.3 {
                timePitch.overlap = 32  // Maximum quality for extreme speed changes
            } else if deviation > 0.1 {
                timePitch.overlap = 24  // High quality for moderate changes
            } else {
                timePitch.overlap = 16  // Efficient for near-normal speed
            }
            
            if self.playbackSpeed != 2.0 {
                self.savedPlaybackSpeed = self.playbackSpeed
            }
            
            // If we crossed the 1.0x threshold, reinstall the tap on the appropriate node
            let crossedThreshold = (previousSpeed < 1.0 && self.playbackSpeed >= 1.0) ||
                                   (previousSpeed >= 1.0 && self.playbackSpeed < 1.0)
            
            if crossedThreshold && self.isPlaying {
                print("⚡ Playback speed crossed 1.0x threshold, reinstalling visualizer tap")
                self.removeVisualizationTap()
                self.installVisualizationTap()
            }
            
            DispatchQueue.main.async {
                self.updateNowPlayingInfo()
            }
            
            print("⚡ Speed: \(self.playbackSpeed)x, overlap: \(timePitch.overlap)")
        }
    }
    
    private func applyPitch() {
        audioQueue.async {
            guard let timePitch = self.timePitchNode else { return }
            
            // Bypass check - zero out pitch when bypassed
            let pitch = self.effectsBypass ? 0 : Float(self.pitchShift * 100)
            
            timePitch.pitch = pitch
            
            let deviation = abs(self.pitchShift)
            if deviation > 4 {
                timePitch.overlap = max(timePitch.overlap, 32)
            } else if deviation > 2 {
                timePitch.overlap = max(timePitch.overlap, 24)
            }
            
            print("🎵 Pitch: \(self.pitchShift) st, overlap: \(timePitch.overlap)")
        }
    }
    
    private func applyBassBoost() {
        audioQueue.async {
            guard let eq = self.eqNode else { return }
            
            // If bypassed, zero out all EQ bands
            if self.effectsBypass {
                for band in eq.bands {
                    band.gain = 0
                }
                return
            }
            
            let boost = self.bassBoost  // -10 to +20 dB from user
            
            // ── 5-band surgical bass shaping ──
            // Instead of a single shelf that makes everything muddy, we:
            //   1. Boost sub-bass (40Hz) for the physical chest-thump
            //   2. Boost mid-bass (120Hz) at ~60% of the sub for warmth without boom
            //   3. CUT 300Hz proportionally to remove the mud that bass boost creates
            //   4. Add a touch of 3kHz presence so the mix doesn't sound dark/muffled
            //   5. Add a tiny bit of air (10kHz) to retain sparkle
            
            // Band 0: Sub-bass — full user boost
            eq.bands[0].gain = Float(boost)
            
            // Band 1: Mid-bass — 60% of boost for warmth, not boom
            eq.bands[1].gain = Float(boost * 0.6)
            
            // Band 2: Mud scoop — always cut proportionally when boosting bass
            // When cutting bass (negative), don't add mud
            if boost > 0 {
                // At extreme boosts (>12dB), be more aggressive with mud cut
                let mudCutRatio = boost > 12 ? 0.4 : 0.35
                eq.bands[2].gain = Float(-boost * mudCutRatio)
            } else {
                eq.bands[2].gain = 0
            }
            
            // Band 3: Presence compensation — keeps vocals/snares from drowning
            if boost > 0 {
                // Increase presence more at extreme bass levels
                let presenceRatio = boost > 12 ? 0.2 : 0.15
                eq.bands[3].gain = Float(boost * presenceRatio)
            } else {
                eq.bands[3].gain = 0
            }
            
            // Band 4: Air — subtle sparkle to offset bass darkness
            if boost > 0 {
                // More air at extreme bass to maintain clarity
                let airRatio = boost > 12 ? 0.12 : 0.1
                eq.bands[4].gain = Float(boost * airRatio)
            } else {
                eq.bands[4].gain = 0
            }
            
            print("🔊 Bass EQ: sub=\(eq.bands[0].gain)dB, mid=\(eq.bands[1].gain)dB, mud=\(eq.bands[2].gain)dB, presence=\(eq.bands[3].gain)dB, air=\(eq.bands[4].gain)dB")
        }
    }
    
    func previous() {
        if isPlaylistMode {
            if !previousQueue.isEmpty {
                // Put current track back at the front of the queue
                if let current = currentTrack {
                    queue.insert(current, at: 0)
                    // If current is a playlist track, restore the index
                    if let currentIdx = currentPlaylist.firstIndex(where: { $0.id == current.id }) {
                        currentIndex = currentIdx
                    }
                }
                
                // Play the previous track
                let previousTrack = previousQueue.removeLast()
                // If the previous track is a playlist track, update index
                if let prevIdx = currentPlaylist.firstIndex(where: { $0.id == previousTrack.id }) {
                    currentIndex = prevIdx
                }
                play(previousTrack)
            } else {
                seek(to: 0)
            }
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
        
        // ✅ FIXED: Add current track to previousQueue in BOTH modes
        if let current = currentTrack {
            previousQueue.append(current)
        }
        
        // ✅ FIXED: Always check queue first, even in playlist mode
        // This lets queued songs play between playlist tracks
        if !queue.isEmpty {
            let nextTrack = queue.removeFirst()
            play(nextTrack)
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
            DispatchQueue.main.async {
                self.stop()
                self.onPlaybackEnded?()
            }
        }
    }
    
    var upNextTracks: [Track] {
        if isPlaylistMode && !currentPlaylist.isEmpty {
            // Show queued songs first, then remaining playlist tracks
            var upcoming: [Track] = []
            upcoming.append(contentsOf: queue)
            let nextIndex = currentIndex + 1
            if nextIndex < currentPlaylist.count {
                upcoming.append(contentsOf: currentPlaylist[nextIndex...])
            }
            return upcoming
        }
        return queue
    }
    
    // Playlist-only upcoming tracks (excludes manually queued songs)
    var playlistUpNextTracks: [Track] {
        guard isPlaylistMode, !currentPlaylist.isEmpty else { return [] }
        let nextIndex = currentIndex + 1
        if nextIndex < currentPlaylist.count {
            return Array(currentPlaylist[nextIndex...])
        }
        return []
    }
    
    func addToQueue(_ track: Track) {
        DispatchQueue.main.async {
            self.queue.append(track)
        
            // ✅ AUTO-DISABLE: Disable loop when adding to queue
            if self.isLoopEnabled {
                self.isLoopEnabled = false
                print("🔁 [AudioPlayer] Loop disabled - song added to queue")
            }
            
            if self.currentTrack == nil {
                // Only exit playlist mode if nothing is playing
                if !self.isPlaylistMode {
                    let firstTrack = self.queue.removeFirst()
                    self.play(firstTrack)
                } else {
                    // In playlist mode with no current track, play from queue
                    let firstTrack = self.queue.removeFirst()
                    self.play(firstTrack)
                }
            }
        }
    }
    
    func playNext(_ track: Track) {
        DispatchQueue.main.async {
            self.queue.insert(track, at: 0)
        
            // ✅ AUTO-DISABLE: Disable loop when playing next
            if self.isLoopEnabled {
                self.isLoopEnabled = false
                print("🔁 [AudioPlayer] Loop disabled - song queued to play next")
            }
            
            if self.currentTrack == nil {
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
    // ✅ AUTO-DISABLE: Disable loop when playing from queue
        if isLoopEnabled {
            isLoopEnabled = false
            print("🔁 [AudioPlayer] Loop disabled - playing from queue")
        }
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

    // MARK: - FFT-Based Visualization with Beat Detection

    

    private func installVisualizationTap() {
        guard let engine = audioEngine, let player = playerNode else { return }
        
        // Remove existing tap if present
        if visualizationTapInstalled {
            removeVisualizationTap()
        }
        
        if fftSetup == nil {
            fftLog2n = vDSP_Length(log2(Float(fftSize)))
            fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))
        }
        
        // Reset beat detection state for new track
        resetBeatDetectionState()
        
        // Choose tap location based on playback speed
        // For speeds < 1.0x: Use mixer output (maintains real-time visualization)
        // For speeds >= 1.0x: Use player output (visualization speeds up with audio)
        if playbackSpeed < 1.0 {
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            // Safety: Remove any existing tap first
            if engine.mainMixerNode.numberOfInputs > 0 {
                engine.mainMixerNode.removeTap(onBus: 0)
            }
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: visualizationBufferSize, format: format) { [weak self] buffer, _ in
                self?.processFFTBuffer(buffer)
            }
            visualizationTapOnMixer = true
            print("✅ [AudioPlayer] Visualizer installed on mixer output (slow playback mode)")
        } else {
            let format = player.outputFormat(forBus: 0)
            // Safety: Remove any existing tap first
            player.removeTap(onBus: 0)
            player.installTap(onBus: 0, bufferSize: visualizationBufferSize, format: format) { [weak self] buffer, _ in
                self?.processFFTBuffer(buffer)
            }
            visualizationTapOnMixer = false
            print("✅ [AudioPlayer] Visualizer installed on player output (normal/fast playback mode)")
        }
        
        visualizationTapInstalled = true
    }
    
    private func resetBeatDetectionState() {
        previousMagnitudes = [Float](repeating: 0, count: fftSizeHalf)
        energyHistory = [Float](repeating: 0, count: 43)
        fluxHistory = [Float](repeating: 0, count: 43)
        subBassHistory = [Float](repeating: 0, count: 20)
        bassHistory = [Float](repeating: 0, count: 20)
        lowMidHistory = [Float](repeating: 0, count: 20)
        energyHistoryIndex = 0
        fluxHistoryIndex = 0
        subBassHistoryIndex = 0
        beatIntensity = 0
        lastBeatTime = 0
        adaptiveThreshold = 0.5
        peakEnergy = 0.01
        avgEnergy = 0.01
        runningMax = 0.001
        runningAvg = 0.001
        sampleCount = 0
        smoothedBins = [Float](repeating: 0, count: 100)
        smoothedBass = 0
        
        // ✅ ADDED: Force update UI to zero immediately
        // ✅ CHANGED: Use async dispatch to avoid blocking
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.frequencyBins = [Float](repeating: 0, count: 100)
            self.bassLevel = 0
        }
    }

    private func removeVisualizationTap() {
        guard let engine = audioEngine, let player = playerNode else {
            visualizationTapInstalled = false
            visualizationTapOnMixer = false
            return
        }
        
        // Only remove from the node that actually has the tap
        if visualizationTapOnMixer {
            if engine.mainMixerNode.numberOfInputs > 0 {
                engine.mainMixerNode.removeTap(onBus: 0)
                print("✅ [AudioPlayer] Visualization tap removed from mixer")
            }
        } else {
            player.removeTap(onBus: 0)
            print("✅ [AudioPlayer] Visualization tap removed from player")
        }
        
        visualizationTapInstalled = false
        visualizationTapOnMixer = false
    }

    /// Advanced FFT-based frequency analysis with beat detection
    private func processFFTBuffer(_ buffer: AVAudioPCMBuffer) {
        PerformanceMonitor.shared.start("processFFTBuffer") // ✅ ADDED
        defer { PerformanceMonitor.shared.end("processFFTBuffer") } // ✅ ADDED
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        
        let samples = channelData[0]
        let samplesToProcess = min(frameLength, fftSize)
        
        // ==========================================
        // STEP 1: Apply Hann window for clean FFT
        // ==========================================
        for i in 0..<fftSize {
            if i < samplesToProcess {
                let window = 0.5 * (1.0 - cos(2.0 * .pi * Float(i) / Float(samplesToProcess)))
                fftInputBuffer[i] = samples[i] * window
            } else {
                fftInputBuffer[i] = 0
            }
        }
        
        // ==========================================
        // STEP 2: Perform FFT using vDSP
        // ==========================================
        fftInputBuffer.withUnsafeBufferPointer { inputPtr in
            fftReal.withUnsafeMutableBufferPointer { realPtr in
                fftImag.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    
                    inputPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSizeHalf))
                    }
                    
                    if let setup = fftSetup {
                        vDSP_fft_zrip(setup, &splitComplex, 1, fftLog2n, FFTDirection(kFFTDirection_Forward))
                    }
                    
                    vDSP_zvmags(&splitComplex, 1, &fftMagnitudes, 1, vDSP_Length(fftSizeHalf))
                }
            }
        }
        
        // Convert to magnitude (sqrt of power)
        for i in 0..<fftSizeHalf {
            fftMagnitudes[i] = sqrt(fftMagnitudes[i])
        }
        
        // ==========================================
        // STEP 3: Calculate spectral flux (onset detection)
        // Spectral flux measures how much the spectrum changed
        // Large positive changes indicate beats/transients
        // ==========================================
        var spectralFlux: Float = 0
        for i in 0..<fftSizeHalf {
            let diff = fftMagnitudes[i] - previousMagnitudes[i]
            if diff > 0 {  // Only count increases (onsets, not decays)
                spectralFlux += diff * diff
            }
            previousMagnitudes[i] = fftMagnitudes[i]
        }
        spectralFlux = sqrt(spectralFlux)
        
        // ==========================================
        // STEP 4: Sub-band energy analysis
        // At 44.1kHz with fftSize 2048: each bin = ~21.5Hz
        // Sub-bass (kick): 20-60Hz = bins 1-3
        // Bass: 60-250Hz = bins 3-12
        // Low-mid: 250-500Hz = bins 12-23
        // Mid: 500-2000Hz = bins 23-93
        // High: 2000-8000Hz = bins 93-372
        // ==========================================
        
        var subBassEnergy: Float = 0
        var bassEnergy: Float = 0
        var lowMidEnergy: Float = 0
        var midEnergy: Float = 0
        var highEnergy: Float = 0
        
        // Sub-bass (kick drum) - very narrow, focused on punch
        for i in 1..<4 {
            subBassEnergy += fftMagnitudes[i] * fftMagnitudes[i]
        }
        subBassEnergy = sqrt(subBassEnergy / 3.0) * 1.3  // Boost sub-bass detection
        
        // Bass
        for i in 3..<12 {
            bassEnergy += fftMagnitudes[i] * fftMagnitudes[i]
        }
        bassEnergy = sqrt(bassEnergy / 9.0) * 1.2  // Boost bass detection
        
        // Low-mid (snare body, toms)
        for i in 12..<23 {
            lowMidEnergy += fftMagnitudes[i] * fftMagnitudes[i]
        }
        lowMidEnergy = sqrt(lowMidEnergy / 11.0)
        
        // Mid
        for i in 23..<93 {
            midEnergy += fftMagnitudes[i] * fftMagnitudes[i]
        }
        midEnergy = sqrt(midEnergy / 70.0)
        
        // High (hi-hats, cymbals)
        for i in 93..<min(372, fftSizeHalf) {
            highEnergy += fftMagnitudes[i] * fftMagnitudes[i]
        }
        highEnergy = sqrt(highEnergy / Float(min(279, fftSizeHalf - 93)))
        
        // Total energy
        let totalEnergy = subBassEnergy + bassEnergy + lowMidEnergy + midEnergy * 0.5 + highEnergy * 0.3
        
        // ==========================================
        // STEP 5: Update history buffers
        // ==========================================
        energyHistory[energyHistoryIndex] = totalEnergy
        energyHistoryIndex = (energyHistoryIndex + 1) % energyHistory.count
        
        fluxHistory[fluxHistoryIndex] = spectralFlux
        fluxHistoryIndex = (fluxHistoryIndex + 1) % fluxHistory.count
        
        subBassHistory[subBassHistoryIndex] = subBassEnergy
        bassHistory[subBassHistoryIndex] = bassEnergy
        lowMidHistory[subBassHistoryIndex] = lowMidEnergy
        subBassHistoryIndex = (subBassHistoryIndex + 1) % subBassHistory.count
        
        // ==========================================
        // STEP 6: Calculate adaptive thresholds
        // ==========================================
        
        // Average and variance of recent energy
        var avgEnergyLocal: Float = 0
        var varianceEnergy: Float = 0
        for e in energyHistory {
            avgEnergyLocal += e
        }
        avgEnergyLocal /= Float(energyHistory.count)
        
        for e in energyHistory {
            let diff = e - avgEnergyLocal
            varianceEnergy += diff * diff
        }
        varianceEnergy = sqrt(varianceEnergy / Float(energyHistory.count))
        
        // Average of recent flux
        var avgFlux: Float = 0
        for f in fluxHistory {
            avgFlux += f
        }
        avgFlux /= Float(fluxHistory.count)
        
        // Sub-band averages for relative comparison
        var avgSubBass: Float = 0
        var avgBass: Float = 0
        for i in 0..<subBassHistory.count {
            avgSubBass += subBassHistory[i]
            avgBass += bassHistory[i]
        }
        avgSubBass /= Float(subBassHistory.count)
        avgBass /= Float(subBassHistory.count)
        
        // ==========================================
        // STEP 7: BEAT DETECTION
        // A beat is detected when:
        // 1. Current energy exceeds adaptive threshold
        // 2. OR spectral flux exceeds threshold (transient)
        // 3. OR sub-bass has a sudden spike (kick drum)
        // ==========================================
        
        let energyThreshold = avgEnergyLocal + varianceEnergy * 0.9  // Even more sensitive
        let fluxThreshold = avgFlux * 1.4  // More sensitive
        let subBassThreshold = avgSubBass * 1.2  // Much more sensitive to bass
        
        let now = CFAbsoluteTimeGetCurrent()
        let minBeatInterval: CFAbsoluteTime = 0.14  // Allow even faster beats
        
        var beatDetected = false
        var beatStrength: Float = 0
        
        if now - lastBeatTime >= minBeatInterval {
            // Check for beat conditions (more aggressive, especially for bass)
            let energyBeat = totalEnergy > energyThreshold && totalEnergy > avgEnergyLocal * 1.15
            let fluxBeat = spectralFlux > fluxThreshold && spectralFlux > avgFlux * 1.25
            let kickBeat = subBassEnergy > subBassThreshold && subBassEnergy > avgSubBass * 1.15  // More bass-focused
            
            if energyBeat || fluxBeat || kickBeat {
                beatDetected = true
                
                // Calculate beat strength based on how much it exceeds thresholds
                var strength: Float = 0
                if energyBeat {
                    strength = max(strength, (totalEnergy - energyThreshold) / (avgEnergyLocal + 0.001))
                }
                if fluxBeat {
                    strength = max(strength, (spectralFlux - fluxThreshold) / (avgFlux + 0.001))
                }
                if kickBeat {
                    // Give extra weight to bass hits
                    strength = max(strength, (subBassEnergy - subBassThreshold) / (avgSubBass + 0.001) * 1.2)
                }
                
                beatStrength = min(1.0, strength * 0.8)  // Even stronger beat response
                lastBeatTime = now
            }
        }
        
        // ==========================================
        // STEP 8: Update beat intensity with proper envelope
        // Attack: instant on beat
        // Decay: fast falloff for punchier feel
        // ==========================================
        
        if beatDetected {
            // Instant attack - jump to beat strength
            beatIntensity = max(beatIntensity, 0.65 + beatStrength * 0.35)  // Stronger punch
        } else {
            // Faster decay for punchy feel - doesn't stay static
            beatIntensity *= beatDecayRate
        }
        beatIntensity = min(1.0, max(0, beatIntensity))
        
        // ==========================================
        // STEP 9: Map frequency bins for visualization
        // Use logarithmic mapping for more musical distribution
        // ==========================================
        
        // Update running statistics
        sampleCount += 1
        if totalEnergy > runningMax {
            runningMax = totalEnergy
        } else {
            runningMax = runningMax * 0.9995 + totalEnergy * 0.0005  // Very slow decay
        }
        runningAvg = runningAvg * 0.99 + totalEnergy * 0.01
        
        let normalizer = max(runningMax, runningAvg * 2, 0.001)
        
        // Create frequency bins with logarithmic mapping
        var rawBins = [Float](repeating: 0, count: 100)
        
        // Map 100 bins across useful frequency range (20Hz - 8000Hz)
        // Using logarithmic scale so bass/mid gets more bins
        let minFreq: Float = 20.0
        let maxFreq: Float = 8000.0
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let sampleRate: Float = 44100.0
        let binWidth = sampleRate / Float(fftSize)
        
        for i in 0..<100 {
            // Logarithmic frequency mapping
            let t = Float(i) / 99.0
            let freq = pow(10, logMin + t * (logMax - logMin))
            let fftBin = Int(freq / binWidth)
            
            guard fftBin < fftSizeHalf else { continue }
            
            // Average a few bins around the target for smoother result
            var mag: Float = 0
            var count: Float = 0
            let spread = max(1, fftBin / 10)  // More averaging for higher bins
            for j in max(0, fftBin - spread)...min(fftSizeHalf - 1, fftBin + spread) {
                mag += fftMagnitudes[j]
                count += 1
            }
            mag /= count
            
            rawBins[i] = mag
        }
        
        // ==========================================
        // STEP 10: Normalize and apply beat modulation
        // ==========================================
        
        var orderedBins = [Float](repeating: 0, count: 100)
        
        for i in 0..<100 {
            // Normalize
            var value = rawBins[i] / normalizer
            
            // Apply power curve for better visual dynamics
            value = pow(value, 0.6)
            
            // Modulate by beat intensity - bars pulse with the beat
            // Stronger effect on bass frequencies (lower indices)
            let beatModulation = beatIntensity * (1.0 - Float(i) / 150.0)  // Decreases toward high freqs
            value = value * (0.55 + beatModulation * 0.9)  // 55-145% based on beat (even more punch!)
            
            value = min(1.0, max(0, value))
            
            // Smooth with different attack/decay for PUNCHY feel
            let smoothUp: Float = 0.90    // Near-instant attack
            let smoothDown: Float = 0.35  // Even faster decay - won't stay static
            
            if value > smoothedBins[i] {
                smoothedBins[i] = smoothedBins[i] + (value - smoothedBins[i]) * smoothUp
            } else {
                smoothedBins[i] = smoothedBins[i] + (value - smoothedBins[i]) * smoothDown
            }
            
            // NO artificial floor - 0 means no activity, lines should be invisible
            // Values naturally range 0-1 based on actual audio energy
            orderedBins[i] = min(1.0, max(0, smoothedBins[i]))
        }
        
        // Shuffle for visual distribution
        var newBins = [Float](repeating: 0, count: 100)
        for i in 0..<100 {
            newBins[shuffledIndices[i]] = orderedBins[i]
        }
        
        // ==========================================
        // STEP 11: Bass level for thumbnail pulse
        // Combine beat intensity with low frequency energy
        // ==========================================
        
        // Weighted combination of sub-bass, bass, and beat intensity
        let combinedBass = (subBassEnergy * 1.2 + bassEnergy * 0.6) / normalizer  // More bass weight
        let normalizedBass = pow(min(1.0, combinedBass), 0.5)  // Even more sensitive power curve
        
        // Mix frequency content with beat detection for the pulse
        // 75% beat intensity, 25% frequency content - heavily favor beat detection for punch
        let targetBass = beatIntensity * 0.75 + normalizedBass * 0.25
        
        // Smooth the bass level with VERY PUNCHY envelope - won't stay static
        if targetBass > smoothedBass {
            smoothedBass = smoothedBass + (targetBass - smoothedBass) * 0.92  // Near-instant attack
        } else {
            smoothedBass = smoothedBass + (targetBass - smoothedBass) * 0.35  // Much faster decay
        }
        
        // NO artificial floor - 0 means no pulse, thumbnail stays static
        smoothedBass = min(1.0, max(0, smoothedBass))
        
        // ==========================================
        // STEP 12: Throttled update to SwiftUI
        // ==========================================
        let finalBins = newBins
        let finalBass = smoothedBass
        
        let updateNow = CFAbsoluteTimeGetCurrent()
        if updateNow - lastVisualizationUpdate >= visualizationUpdateInterval {
            lastVisualizationUpdate = updateNow
    
            PerformanceMonitor.shared.start("FFT_to_SwiftUI") // ✅ ADDED
            DispatchQueue.main.async { [weak self] in
                self?.frequencyBins = finalBins
                self?.bassLevel = finalBass
                PerformanceMonitor.shared.end("FFT_to_SwiftUI") // ✅ ADDED
            }
        }
    }
}