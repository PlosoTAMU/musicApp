import Foundation
import AVFoundation
import MediaPlayer
import Accelerate

class VisualizerState: ObservableObject {
    var bassLevel: Float = 0
    var frequencyBins: [Float] = Array(repeating: 0, count: 100)
    /// Predictive head-nod displacement (0-1) from BeatEngine — tempo-locked,
    /// beat-phase driven. Use THIS for the thumping icon, not bassLevel.
    var nod: Float = 0
    /// BeatEngine lock quality (0-1) — UI can subtly reward a strong lock.
    var beatConfidence: Float = 0

    /// Single batched update — fires objectWillChange exactly ONCE per frame
    func update(bins: [Float], bass: Float, nod: Float = 0, confidence: Float = 0) {
        PerformanceMonitor.shared.recordStateChange("visualizerState.update")
        objectWillChange.send()
        frequencyBins = bins
        bassLevel = bass
        self.nod = nod
        self.beatConfidence = confidence
    }
}


class AudioPlayerManager: NSObject, ObservableObject {
    @Published var isPlaying = false {
        didSet { PerformanceMonitor.shared.recordStateChange("audioPlayer.isPlaying") }
    }
    @Published var currentTrack: Track? {
        didSet { PerformanceMonitor.shared.recordStateChange("audioPlayer.currentTrack") }
    }
    
    // ✅ Visualization lifecycle — tap is only active when visualizer is on-screen
    var isVisualizerVisible = false
    @Published var currentPlaylist: [Track] = []
    @Published var queue: [Track] = []
    @Published var previousQueue: [Track] = []
    @Published var isPlaylistMode = false
    @Published var isLoopEnabled = false
    @Published var currentIndex: Int = 0
    @Published var currentTime: Double = 0 {
        didSet { PerformanceMonitor.shared.recordStateChange("audioPlayer.currentTime") }
    }
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
    
    @Published var effectsBypass: Bool = true {
        didSet {
            // Re-apply all effects with bypass state
            applyReverb()
            applyBassBoost()
            applyPitch()
            applyPlaybackSpeed()
        }
    }

    /// Timestamp of when the current track was last paused (for auto-restart logic)
    private var lastPausedAt: Date? = nil

    /// If paused longer than this, restart the song from the beginning
    private let autoRestartThreshold: TimeInterval = 60.0 // 1 minute
    
    // Computed property that returns the actual effective playback speed
    // (accounts for bypass - when bypassed, speed is always 1.0)
    var effectivePlaybackSpeed: Double {
        if temporarySpeedOverride != nil { return temporarySpeedOverride! }
        return effectsBypass ? 1.0 : playbackSpeed
    }
    
    // Temporary speed override for hold-to-fast-forward (works even with DJ mode off)
    var temporarySpeedOverride: Double? = nil
    
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
    
    // Debounce timer for saving track settings to disk
    private var saveSettingsTimer: Timer?
    
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
    
    let visualizerState = VisualizerState()
    
    // Deterministic musical bar layout, replacing the old random shuffle:
    // bottom = bass (deepest at center), mids climb the sides, highs sparkle
    // across the top (brightest at center). Slots: 0-24 top (L→R), 25-49 right
    // (T→B), 50-74 bottom (R→L), 75-99 left (B→T) — matches the draw order in
    // EdgeVisualizerView.
    private lazy var spatialMap: [Int] = {
        var map = [Int](repeating: 0, count: 100)
        func centerOut(_ k: Int) -> Int {   // 12→0, 11→1, 13→2, 10→3, …
            let m = abs(k - 12)
            return k < 12 ? 2 * m - 1 : 2 * m
        }
        for k in 0..<25 {
            map[k]      = 75 + centerOut(k)     // top ← highs, center-out
            map[25 + k] = 25 + 2 * (24 - k)     // right ← odd-step mids, low near bottom
            map[50 + k] = centerOut(k)          // bottom ← bass, deepest center
            map[75 + k] = 26 + 2 * k            // left ← even-step mids, low near bottom
        }
        return map
    }()
    
    private var lastVisualizationUpdate: CFAbsoluteTime = 0
    private let visualizationUpdateInterval: CFAbsoluteTime = 1.0 / 60.0  // KEEP THIS -- 60fps is NEEDED.
    
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
    
    // Pre-allocated work buffers (avoid per-frame heap allocation)
    private var rawBins = [Float](repeating: 0, count: 100)
    private var orderedBins = [Float](repeating: 0, count: 100)
    private var newBins = [Float](repeating: 0, count: 100)
    
    // ==========================================
    // PREDICTIVE BEAT TRACKING (BeatEngine) + PER-BAND AGC
    // ==========================================

    /// Tempo + phase tracker — the "human head-nod" model. See BeatEngine.swift.
    private let beatEngine = BeatEngine()

    // Previous frame's LOG-magnitudes for spectral-flux onset detection
    // (log flux is level-invariant: quiet tracks onset just as clearly).
    private var previousMagnitudes = [Float](repeating: 0, count: 1024)

    // Measured tap cadence (AVAudioEngine ignores requested buffer sizes).
    private var lastTapTime: CFAbsoluteTime = 0

    // Smoothed loudness gate (0-1): silences fade the whole visualizer out.
    private var energyGate: Float = 0

    // Per-band automatic gain: each of the 100 display bins is normalized
    // against its OWN running floor/peak, so every band uses the full visual
    // range regardless of genre or mix balance — "vibrant no matter the music".
    private var binPeak = [Float](repeating: 0.001, count: 100)
    private var binFloor = [Float](repeating: 0, count: 100)

    // Running statistics for the global loudness gate
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
        
        // ✅ Register PerformanceMonitor categories
        PerformanceMonitor.shared.registerCategory("Canvas_EdgeVisualizer_Draw", .rendering)
        PerformanceMonitor.shared.registerCategory("NowPlayingView_UpdateBackground", .rendering)
        
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
        
        // Update in-memory dictionary immediately
        trackSettings[trackID] = TrackSettings(
            playbackSpeed: playbackSpeed,
            reverbAmount: reverbAmount,
            pitchShift: pitchShift,
            bassBoost: bassBoost
        )
        
        // Debounce disk write — coalesce rapid slider changes into a single write
        saveSettingsTimer?.invalidate()
        saveSettingsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.saveTrackSettingsToDisk()
        }
    }
    
    // ✅ NEW: Write settings to disk (called from debounce timer, off main thread)
    private func saveTrackSettingsToDisk() {
        let settingsSnapshot = trackSettings
        let fileURL = trackSettingsFileURL
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try JSONEncoder().encode(settingsSnapshot)
                try data.write(to: fileURL, options: .atomic)
                print("💾 [AudioPlayer] Saved settings for \(settingsSnapshot.count) tracks")
            } catch {
                print("❌ [AudioPlayer] Failed to save track settings: \(error)")
            }
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
        
        // Enable previous/next track (shows « and »)
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        
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
        
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: event.positionTime)
                return .success
            }
            return .commandFailed
        }
        
        // Disable +10/-10 so iOS shows « » instead
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
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
    
    /// - Parameters:
    ///   - startOffset: seconds (relative to crop start) to begin playback at.
    ///     Used by the sync engine for session-handover continuity.
    ///   - startPaused: hand over into a paused state — loads track metadata and
    ///     arms resume() at startOffset without scheduling any audio.
    func play(_ track: Track, at startOffset: Double = 0, startPaused: Bool = false) {
        PerformanceMonitor.shared.start("AudioPlayer_Play") // ✅ ADDED
        defer { PerformanceMonitor.shared.end("AudioPlayer_Play") } // ✅ ADDED
        currentPlaybackSessionID = UUID()
        let sessionID = currentPlaybackSessionID
        hasTriggeredNext = false  // ✅ RESET: New track, allow next() to be triggered again
        lastPausedAt = nil  // ✅ Reset pause timestamp on new play
    
        // ✅ FIX: Reset visualization IMMEDIATELY and SYNCHRONOUSLY
        // This ensures UI shows zero before any async work happens
        if Thread.isMainThread {
            self.visualizerState.update(bins: [Float](repeating: 0, count: 100), bass: 0)
        } else {
            DispatchQueue.main.sync {
                self.visualizerState.update(bins: [Float](repeating: 0, count: 100), bass: 0)
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
                
                // ✅ Handle crop times - determine which segment of the file to play
                let totalFileLength = AVAudioFrameCount(file.length)
                let sampleRate = file.fileFormat.sampleRate
                
                let cropStart = track.cropStartTime ?? 0.0
                let cropEnd = track.cropEndTime ?? (Double(totalFileLength) / sampleRate)

                // ✅ SYNC: clamp handover offset inside the cropped segment
                let safeOffset = min(max(0, startOffset), max(0, (cropEnd - cropStart) - 0.5))

                // ✅ SYNC: paused handover — set metadata only; resume() reschedules
                // from savedCurrentTime when the user presses play.
                if startPaused {
                    DispatchQueue.main.async {
                        self.currentTrack = track
                        self.duration = cropEnd - cropStart
                        self.currentTime = safeOffset
                        self.savedCurrentTime = safeOffset
                        self.seekOffset = safeOffset
                        self.needsReschedule = true
                        self.isPlaying = false
                        self.lastPausedAt = Date()
                        self.applyTrackSettings(for: track)
                        self.updateNowPlayingInfo()
                    }
                    return
                }

                let startFrame = AVAudioFramePosition((cropStart + safeOffset) * sampleRate)
                let endFrame = AVAudioFramePosition(cropEnd * sampleRate)
                let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
                
                // Schedule the cropped segment
                player.scheduleSegment(file,
                                      startingFrame: startFrame,
                                      frameCount: frameCount,
                                      at: nil)
                
                // Schedule silence padding after the file (0.5s)
                let paddingFrames = AVAudioFrameCount(0.5 * sampleRate)
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
                    guard let self = self, self.isVisualizerVisible else { return }
                    self.resetBeatDetectionState()
                    self.installVisualizationTap()
                }
                
                // ✅ Calculate duration (respecting crop times)
                let croppedDuration = cropEnd - cropStart
                
                DispatchQueue.main.async {
                    self.isPlaying = true
                    self.currentTrack = track
                    self.savedCurrentTime = safeOffset
                    self.currentTime = safeOffset
                    self.seekOffset = safeOffset   // ✅ SYNC: updateTime() adds this to player position
                    self.duration = croppedDuration
                    
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
        lastPausedAt = Date() // ✅ Track when we paused
        
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
        
        // ✅ NEW: If paused for more than 1 minute, restart from the beginning
        if let pausedAt = lastPausedAt {
            let elapsed = Date().timeIntervalSince(pausedAt)
            if elapsed > autoRestartThreshold {
                print("⏪ [AudioPlayer] Paused for \(Int(elapsed))s (>\(Int(autoRestartThreshold))s), restarting from beginning")
                savedCurrentTime = 0
                needsReschedule = true
            }
        }
        lastPausedAt = nil // ✅ Clear — we're no longer paused
        
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
            
            // ✅ Handle crop times: user time is relative to crop start
            let cropStart = track.cropStartTime ?? 0.0
            let totalFileLength = AVAudioFrameCount(file.length)
            let cropEnd = track.cropEndTime ?? (Double(totalFileLength) / sampleRate)
            
            // Convert user time to absolute file time
            let absoluteResumeTime = cropStart + resumeTime
            let startFrame = AVAudioFramePosition(max(0, absoluteResumeTime) * sampleRate)
            let cropEndFrame = AVAudioFramePosition(cropEnd * sampleRate)
            
            print("🔄 Resuming from \(resumeTime)s user time (\(absoluteResumeTime)s file time, frame: \(startFrame))")
            
            if startFrame < cropEndFrame && startFrame >= 0 {
                // ✅ Schedule from resume position to crop end (not file end)
                let remainingFrames = AVAudioFrameCount(cropEndFrame - startFrame)
                let paddingFrames = AVAudioFrameCount(0.5 * sampleRate)
                
                // Schedule remaining cropped audio
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
                // At or past the end — skip to next track
                DispatchQueue.main.async {
                    self.next()
                }
                return
            }
            
            player.play()
            
            // ✅ FIX: Reinstall visualization tap after resume (player.stop() removes it)
            if self.isVisualizerVisible {
                self.resetBeatDetectionState()
                self.installVisualizationTap()
            }
            
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
        guard audioFile != nil else { return }
        
        // ✅ Handle crop times: user time is relative to crop start
        let cropStart = currentTrack?.cropStartTime ?? 0.0
        let absoluteTime = cropStart + time
        
        let clampedTime = max(0, min(time, duration - 0.5))
        let clampedAbsoluteTime = cropStart + clampedTime
        
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
                  let file = self.audioFile,
                  let track = self.currentTrack else { return }
            
            let sampleRate = file.fileFormat.sampleRate
            
            // ✅ Get crop boundaries
            let totalFileLength = AVAudioFrameCount(file.length)
            let cropEnd = track.cropEndTime ?? (Double(totalFileLength) / sampleRate)
            let cropStartFrame = AVAudioFramePosition(cropStart * sampleRate)
            let cropEndFrame = AVAudioFramePosition(cropEnd * sampleRate)
            
            // ✅ Calculate absolute start frame (within the file)
            let startFrame = AVAudioFramePosition(clampedAbsoluteTime * sampleRate)
            
            player.stop()
            
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    print("❌ Failed to start engine for seek: \(error)")
                    return
                }
            }
            
            // ✅ Schedule from seek position to crop end (not file end)
            if startFrame < cropEndFrame && startFrame >= cropStartFrame {
                let remainingFrames = AVAudioFrameCount(cropEndFrame - startFrame)
                
                if remainingFrames > 0 {
                    let paddingFrames = AVAudioFrameCount(0.5 * sampleRate)
                    
                    // Schedule remaining cropped audio
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
    
    // Force a temporary speed override that works regardless of effects bypass state
    // Used by hold-to-fast-forward button
    func setTemporarySpeed(_ speed: Double?) {
        temporarySpeedOverride = speed
        audioQueue.async { [weak self] in
            guard let self = self,
                  let timePitch = self.timePitchNode else { return }
            let targetRate = Float(speed ?? (self.effectsBypass ? 1.0 : self.playbackSpeed))
            let targetPitch = self.effectsBypass ? Float(0) : Float(self.pitchShift * 100)
            
            // Set overlap high for any speed transition
            let deviation = abs(targetRate - 1.0)
            if deviation > 0.3 {
                timePitch.overlap = 32
            } else if deviation > 0.1 {
                timePitch.overlap = 24
            } else {
                timePitch.overlap = 16
            }
            
            timePitch.rate = targetRate
            timePitch.pitch = targetPitch
            
            if speed == nil {
                // RETURNING to normal speed: the AVAudioUnitTimePitch node has
                // internal resampling buffers that still hold "stretched" audio.
                // Flush them by doing a quick stop→reschedule→play on the player
                // node. This is the same thing pause+play does under the hood.
                self.flushPlayerFromCurrentPosition()
            }
            
            DispatchQueue.main.async {
                self.updateNowPlayingInfo()
            }
        }
    }
    
    /// Flush the time-pitch node's internal buffers by stopping the player node,
    /// rescheduling from the current playback position, and restarting.
    /// Must be called on audioQueue.
    private func flushPlayerFromCurrentPosition() {
        guard let engine = self.audioEngine,
              let player = self.playerNode,
              let file = self.audioFile,
              let track = self.currentTrack,
              let timePitch = self.timePitchNode,
              let eq = self.eqNode,
              let reverb1 = self.reverbNode,
              let reverb2 = self.reverbNode2 else { return }
        
        // Capture position before anything else
        let sampleRate = file.fileFormat.sampleRate
        let cropStart = track.cropStartTime ?? 0.0
        let totalFileLength = AVAudioFrameCount(file.length)
        let cropEnd = track.cropEndTime ?? (Double(totalFileLength) / sampleRate)
        let absoluteTime = cropStart + self.currentTime
        let startFrame = AVAudioFramePosition(max(0, absoluteTime) * sampleRate)
        let cropEndFrame = AVAudioFramePosition(cropEnd * sampleRate)
        
        guard startFrame < cropEndFrame else { return }
        
        let remainingFrames = AVAudioFrameCount(cropEndFrame - startFrame)
        let resumeTime = self.currentTime
        let format = file.processingFormat
        let mixer = engine.mainMixerNode
        
        // Invalidate old completion handlers before player.stop() fires them
        self.currentPlaybackSessionID = UUID()
        let sessionID = self.currentPlaybackSessionID
        self.hasTriggeredNext = true   // block old handlers; reset after stop
        
        // ── Step 1: Fade out over ~30 ms so the cut is inaudible ──
        // The engine keeps running — only the mixer output ramps to 0.
        // This avoids the hardware dropout that engine.stop() causes.
        mixer.outputVolume = 0.0
        
        // ── Step 2: Reset the player and TimePitch node ──
        // engine.stop() / disconnect / reconnect fully clears the TimePitch
        // DSP state (internal resampling buffers), which is what causes the
        // high-pitched artifact when returning from 2x speed.
        player.stop()
        engine.stop()
        
        engine.disconnectNodeInput(player)
        engine.disconnectNodeInput(timePitch)
        engine.disconnectNodeInput(eq)
        engine.disconnectNodeInput(reverb1)
        engine.disconnectNodeInput(reverb2)
        
        timePitch.reset()   // explicitly purge TimePitch's internal state
        
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: eq, format: format)
        engine.connect(eq, to: reverb1, format: format)
        engine.connect(reverb1, to: reverb2, format: format)
        engine.connect(reverb2, to: mixer, format: format)
        
        do {
            try engine.start()
        } catch {
            mixer.outputVolume = 1.0   // restore on failure
            print("❌ Failed to restart engine during flush: \(error)")
            return
        }
        
        // ── Step 3: Schedule audio and start playing (still silent) ──
        self.hasTriggeredNext = false
        
        player.scheduleSegment(file,
                               startingFrame: startFrame,
                               frameCount: remainingFrames,
                               at: nil)
        
        let paddingFrames = AVAudioFrameCount(0.5 * sampleRate)
        if let silenceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: paddingFrames) {
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
        }
        
        self.seekOffset = resumeTime
        player.play()
        
        // Reinstall visualization tap (engine teardown removes it)
        if self.isVisualizerVisible {
            self.resetBeatDetectionState()
            self.installVisualizationTap()
        }
        
        // ── Step 4: Fade back in over ~40 ms ──
        // Small delay lets the engine render a few clean buffers first so
        // there is no audible glitch at the moment the volume returns.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            UIView.animate(withDuration: 0.04) {
                mixer.outputVolume = 1.0
            }
        }
        
        print("🔄 Flushed TimePitch buffers (silent crossfade) at \(resumeTime)s")
    }
    
    private func applyPlaybackSpeed() {
        let previousSpeed = savedPlaybackSpeed
        
        audioQueue.async {
            guard let timePitch = self.timePitchNode else { return }
            
            // When bypassed, reset both speed and pitch to defaults
            let speed = self.effectsBypass ? Float(1.0) : Float(self.playbackSpeed)
            let pitch = self.effectsBypass ? Float(0) : Float(self.pitchShift * 100)
            
            let previousRate = timePitch.rate
            
            // Set overlap appropriate for the target speed
            let deviation = abs(speed - 1.0)
            if deviation > 0.3 {
                timePitch.overlap = 32
            } else if deviation > 0.1 {
                timePitch.overlap = 24
            } else {
                timePitch.overlap = 16
            }
            
            // Apply rate and pitch
            timePitch.rate = speed
            timePitch.pitch = pitch
            
            if self.playbackSpeed != 2.0 {
                self.savedPlaybackSpeed = self.playbackSpeed
            }
            
            // If speed changed significantly while playing, flush the TimePitch
            // buffers by rescheduling. This prevents the "weird audio" artifacts
            // that occur because TimePitch's internal resampling buffers still
            // hold audio processed at the old rate.
            let speedDelta = abs(previousRate - speed)
            if speedDelta > 0.15 && self.isPlaying {
                self.flushPlayerFromCurrentPosition()
            }
            
            // If we crossed the 1.0x threshold, reinstall the tap on the appropriate node
            let crossedThreshold = (previousSpeed < 1.0 && self.playbackSpeed >= 1.0) ||
                                   (previousSpeed >= 1.0 && self.playbackSpeed < 1.0)
            
            if crossedThreshold && self.isPlaying && self.isVisualizerVisible {
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

    /// Queue an entire playlist's tracks without interrupting current playback.
    /// If nothing is playing, starts the first track immediately.
    func queuePlaylist(_ tracks: [Track], shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
        
        let orderedTracks = shuffle ? tracks.shuffled() : tracks
        
        DispatchQueue.main.async {
            if self.isLoopEnabled {
                self.isLoopEnabled = false
                print("🔁 [AudioPlayer] Loop disabled - playlist queued")
            }
            
            if self.currentTrack == nil {
                let first = orderedTracks[0]
                let rest = Array(orderedTracks.dropFirst())
                self.queue.append(contentsOf: rest)
                self.play(first)
                print("📋 [AudioPlayer] Queued \(orderedTracks.count) tracks (started first, shuffle: \(shuffle))")
            } else {
                self.queue.append(contentsOf: orderedTracks)
                print("📋 [AudioPlayer] Queued \(orderedTracks.count) tracks (shuffle: \(shuffle))")
            }
        }
    }
    /// Moves the given tracks to the front of the queue and immediately starts playing the first one.
    func injectAtFrontOfQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        
        DispatchQueue.main.async {
            if self.isLoopEnabled {
                self.isLoopEnabled = false
                print("🔁 [AudioPlayer] Loop disabled - playlist injected")
            }
            
            // Remove these tracks from wherever they currently sit in the queue
            let trackIDs = Set(tracks.map { $0.id })
            self.queue.removeAll { trackIDs.contains($0.id) }
            
            // Put current track into previous queue
            if let current = self.currentTrack {
                self.previousQueue.append(current)
            }
            
            // First track plays now, rest go to front of queue
            let first = tracks[0]
            let rest = Array(tracks.dropFirst())
            self.queue.insert(contentsOf: rest, at: 0)
            self.play(first)
            
            print("⚡ [AudioPlayer] Injected \(tracks.count) tracks at front of queue (playing now)")
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
    
    func clearQueueAndExitPlaylist() {
        DispatchQueue.main.async {
            // Clear only upcoming queue (NOT previous queue - keep history)
            self.queue.removeAll()
            
            // Exit playlist mode
            self.isPlaylistMode = false
            self.currentPlaylist.removeAll()
            self.currentIndex = 0
            
            print("🔄 [AudioPlayer] Cleared upcoming queue and exited playlist mode (kept history)")
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

    // MARK: - Visualization Lifecycle
    
    /// Call when the visualizer view appears on screen
    func startVisualization() {
        isVisualizerVisible = true
        // Only install tap if we're actually playing
        if isPlaying {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.installVisualizationTap()
            }
            print("▶️ [Visualizer] Started — tap installed (playing)")
        } else {
            print("▶️ [Visualizer] Started — waiting for playback")
        }
    }
    
    /// Call when the visualizer view disappears from screen
    func stopVisualization() {
        isVisualizerVisible = false
        removeVisualizationTap()
        // Zero out the state so it doesn't show stale data next time
        visualizerState.update(bins: [Float](repeating: 0, count: 100), bass: 0)
        print("⏹️ [Visualizer] Stopped — tap removed, CPU freed")
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
        beatEngine.reset()
        previousMagnitudes = [Float](repeating: 0, count: fftSizeHalf)
        lastTapTime = 0
        energyGate = 0
        binPeak = [Float](repeating: 0.001, count: 100)
        binFloor = [Float](repeating: 0, count: 100)
        runningMax = 0.001
        runningAvg = 0.001
        sampleCount = 0
        smoothedBins = [Float](repeating: 0, count: 100)
        smoothedBass = 0
        
        // ✅ ADDED: Force update UI to zero immediately
        // ✅ CHANGED: Use async dispatch to avoid blocking
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.visualizerState.update(bins: [Float](repeating: 0, count: 100), bass: 0)
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
    // Pre-computed Hann window (avoids recalculating cos() every frame)
    private lazy var hannWindow: [Float] = {
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return window
    }()
    
    // Pre-computed log frequency mapping (avoids pow/log10 every frame)
    private lazy var frequencyBinMapping: [(fftBin: Int, spread: Int)] = {
        let minFreq: Float = 20.0
        let maxFreq: Float = 8000.0
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let sampleRate: Float = 44100.0
        let binWidth = sampleRate / Float(fftSize)
        
        return (0..<100).map { i in
            let t = Float(i) / 99.0
            let freq = pow(10, logMin + t * (logMax - logMin))
            let fftBin = Int(freq / binWidth)
            let spread = max(1, fftBin / 10)
            return (fftBin: fftBin, spread: spread)
        }
    }()
    
    private func processFFTBuffer(_ buffer: AVAudioPCMBuffer) {
        // ✅ Early exit: skip all FFT work when visualizer isn't visible
        guard isVisualizerVisible else { return }
        
        PerformanceMonitor.shared.recordVisualizationCallback()
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        
        let samples = channelData[0]
        let samplesToProcess = min(frameLength, fftSize)
        
        // ==========================================
        // STEP 1: Apply Hann window using vDSP (vectorized)
        // ==========================================
        if samplesToProcess == fftSize {
            // Fast path: full buffer, use vectorized multiply
            vDSP_vmul(samples, 1, hannWindow, 1, &fftInputBuffer, 1, vDSP_Length(fftSize))
        } else {
            // Partial buffer: window what we have, zero the rest
            for i in 0..<fftSize {
                if i < samplesToProcess {
                    fftInputBuffer[i] = samples[i] * hannWindow[i]
                } else {
                    fftInputBuffer[i] = 0
                }
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
        
        // Convert to magnitude using vectorized sqrt
        var count = Int32(fftSizeHalf)
        vvsqrtf(&fftMagnitudes, fftMagnitudes, &count)
        
        // ==========================================
        // STEP 3: Onset strength — half-wave-rectified LOG-spectral flux.
        // Log magnitudes make onsets level-invariant (quiet tracks register
        // just as clearly); kick-band changes are weighted heaviest because
        // the kick defines the tactus people nod to.
        // ==========================================
        var onsetLow: Float = 0    // 20-250 Hz: kick, bass attacks
        var onsetMid: Float = 0    // 250 Hz-2 kHz: snare body, vocals
        var onsetHigh: Float = 0   // 2-8 kHz: hats, transient sparkle
        let onsetTop = min(372, fftSizeHalf)
        for i in 1..<onsetTop {
            let lm = log(1 + fftMagnitudes[i] * 10)
            let d = lm - previousMagnitudes[i]
            previousMagnitudes[i] = lm
            if d > 0 {
                if i < 12 { onsetLow += d }
                else if i < 93 { onsetMid += d }
                else { onsetHigh += d }
            }
        }
        let onsetStrength = onsetLow * 2.2 + onsetMid * 1.0 + onsetHigh * 0.5
        
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
        // STEP 5: Loudness gate + predictive beat tracking
        // ==========================================

        // Global running stats drive a smoothed 0-1 loudness gate: silence
        // fades everything out instead of the AGC amplifying noise into a
        // light show.
        sampleCount += 1
        if totalEnergy > runningMax {
            runningMax = totalEnergy
        } else {
            runningMax = runningMax * 0.9995 + totalEnergy * 0.0005
        }
        runningAvg = runningAvg * 0.99 + totalEnergy * 0.01

        let loudness = min(1, totalEnergy / max(runningMax * 0.6, 1e-4))
        let gateTarget: Float = totalEnergy < runningMax * 0.02 ? 0 : loudness
        energyGate += (gateTarget - energyGate) * (gateTarget > energyGate ? 0.3 : 0.06)

        // Measured callback cadence — AVAudioEngine ignores requested tap sizes.
        let tapNow = CFAbsoluteTimeGetCurrent()
        let tapDt = lastTapTime > 0 ? Float(tapNow - lastTapTime) : 1.0 / 43.0
        lastTapTime = tapNow

        // Tempo-locked, phase-predicting nod (see BeatEngine.swift).
        let beat = beatEngine.process(onset: onsetStrength, energyGate: energyGate, dt: tapDt)
        
        // ==========================================
        // STEP 9: Map frequency bins for visualization
        // Use logarithmic mapping for more musical distribution
        // ==========================================

        // Create frequency bins using pre-computed logarithmic mapping
        // Re-use pre-allocated buffer
        for i in 0..<100 { rawBins[i] = 0 }
        
        for i in 0..<100 {
            let mapping = frequencyBinMapping[i]
            let fftBin = mapping.fftBin
            let spread = mapping.spread
            
            guard fftBin < fftSizeHalf else { continue }
            
            // Average a few bins around the target for smoother result
            var mag: Float = 0
            var count: Float = 0
            let lo = max(0, fftBin - spread)
            let hi = min(fftSizeHalf - 1, fftBin + spread)
            for j in lo...hi {
                mag += fftMagnitudes[j]
                count += 1
            }
            mag /= count
            
            rawBins[i] = mag
        }
        
        // ==========================================
        // STEP 10: Per-band AGC + beat-phase modulation
        // Each display bin is normalized against its OWN running floor/peak,
        // so a mid-heavy acoustic track fills the range exactly like a
        // bass-heavy club track — vibrant for any music, but still honest:
        // a band with no content stays dark (floor ≈ peak → value ≈ 0).
        // ==========================================

        for i in 0..<100 {
            let mag = rawBins[i]

            // Per-band envelope followers. Peak: instant attack, ~5 s release.
            // Floor: tracks the quietest recent level, creeping upward slowly.
            binPeak[i] = mag > binPeak[i] ? mag : binPeak[i] * 0.9985 + mag * 0.0015
            binFloor[i] = mag < binFloor[i] ? mag : binFloor[i] * 0.999 + mag * 0.001

            let range = binPeak[i] - binFloor[i]
            var value = range > 1e-5 ? (mag - binFloor[i]) / range : 0

            // Perceptual curve + loudness gate (silence darkens everything).
            value = pow(max(0, value), 0.65) * energyGate

            // Beat coupling: the phase-locked pulse breathes through the bars,
            // strongest at the bass end — the frame everything dances inside.
            let beatModulation = beat.pulse * (1.0 - Float(i) / 150.0)
            value *= 0.62 + beatModulation * 0.75

            value = min(1.0, max(0, value))

            // Punchy-but-smooth: fast attack, moderate release.
            let smoothUp: Float = 0.80
            let smoothDown: Float = 0.22
            if value > smoothedBins[i] {
                smoothedBins[i] += (value - smoothedBins[i]) * smoothUp
            } else {
                smoothedBins[i] += (value - smoothedBins[i]) * smoothDown
            }

            orderedBins[i] = min(1.0, max(0, smoothedBins[i]))
        }

        // Deterministic musical layout (bass bottom-center, mids up the sides,
        // highs top-center) — replaces the old random shuffle.
        for slot in 0..<100 {
            newBins[slot] = orderedBins[spatialMap[slot]]
        }
        
        // ==========================================
        // STEP 11: Bass level for thumbnail pulse
        // Derive DIRECTLY from the smoothed bass bars so pulse is perfectly in sync
        // ==========================================
        
        // Average the first 15 orderedBins (bass frequencies) — these are the same
        // values that drive the visible bass bars, already smoothed in Step 10
        var bassBarSum: Float = 0
        for i in 0..<15 {
            bassBarSum += orderedBins[i]
        }
        let avgBassBars = bassBarSum / 15.0
        
        // Apply a slight power curve for punchier feel, then clamp
        smoothedBass = min(1.0, max(0, pow(avgBassBars, 0.8)))

        // ==========================================
        // STEP 12: Nod output + throttled update to SwiftUI
        // ==========================================

        // The icon's thump: the predictive nod when locked; when the tracker
        // has no rhythm to lock onto (ambient, speech), fall back to a gentle
        // bass-envelope breath so the icon never reads as dead.
        let nodOut = max(beat.nod, smoothedBass * 0.35 * (1 - beat.confidence))

        let finalBins = newBins
        let finalBass = smoothedBass
        let finalConfidence = beat.confidence

        let updateNow = CFAbsoluteTimeGetCurrent()
        if updateNow - lastVisualizationUpdate >= visualizationUpdateInterval {
            lastVisualizationUpdate = updateNow

            DispatchQueue.main.async { [weak self] in
                self?.visualizerState.update(bins: finalBins, bass: finalBass,
                                             nod: nodOut, confidence: finalConfidence)
            }
        }
    }
}