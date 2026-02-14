import SwiftUI
import AVFoundation

struct CropSongSheet: View {
    let track: Track
    let downloadManager: DownloadManager
    let audioPlayer: AudioPlayerManager
    @Environment(\.dismiss) var dismiss
    
    @State private var fullDuration: Double = 0
    @State private var startTime: Double = 0
    @State private var endTime: Double = 1
    @State private var isPreviewPlaying = false
    @State private var currentPreviewTime: Double = 0
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewTimer: Timer?
    @State private var wasMainPlayerPlaying = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    @State private var startTimeText: String = ""
    @State private var endTimeText: String = ""
    @State private var isEditingStartTime = false
    @State private var isEditingEndTime = false
    
    // Safe slider ranges
    private var startSliderRange: ClosedRange<Double> {
        0...max(endTime - 0.5, 0)
    }
    private var endSliderRange: ClosedRange<Double> {
        let lower = startTime + 0.5
        return lower...max(lower, fullDuration)
    }
    
    // Display time for the playback position
    private var displayTime: Double {
        isSeeking ? seekPosition : currentPreviewTime
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            Group {
                if let error = loadError {
                    errorView(error)
                } else if isLoading {
                    loadingView
                } else {
                    cropEditorContent
                }
            }
            .navigationTitle("Crop Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        stopPreview()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if audioPlayer.isPlaying {
                wasMainPlayerPlaying = true
                audioPlayer.pause()
            }
            loadAudioDuration()
        }
        .onDisappear {
            stopPreview()
            if wasMainPlayerPlaying {
                audioPlayer.resume()
            }
        }
    }
    
    // MARK: - State Views
    
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            Text("Unable to Load Song")
                .font(.title2)
                .fontWeight(.semibold)
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading song...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Crop Editor
    
    private var cropEditorContent: some View {
        VStack(spacing: 0) {
            // Song info
            VStack(spacing: 8) {
                Text(track.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                HStack(spacing: 16) {
                    Label(formatTime(fullDuration), systemImage: "waveform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Label(formatTime(max(0, endTime - startTime)), systemImage: "scissors")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.blue)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 20)
            
            // Seekable progress bar (like NowPlaying)
            progressBarView
                .padding(.bottom, 24)
            
            // Preview controls
            previewControls
                .padding(.bottom, 20)
            
            Divider().padding(.horizontal, 24)
            
            // Crop range section
            ScrollView {
                VStack(spacing: 20) {
                    cropSliders
                    
                    // Action buttons
                    actionButtons
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
    }
    
    // MARK: - Progress Bar (seekable, like NowPlaying)
    
    private var progressBarView: some View {
        VStack(spacing: 6) {
            // Time labels above the bar
            HStack {
                Text(formatTime(displayTime))
                    .font(.caption)
                    .foregroundColor(.primary)
                    .monospacedDigit()
                
                Spacer()
                
                // Time remaining in crop region
                let remaining = endTime - displayTime
                Text("-\(formatTime(max(0, remaining)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 32)
            
            // The actual seekable bar
            GeometryReader { geometry in
                let width = geometry.size.width
                let safeDuration = max(fullDuration, 0.01)
                
                // Crop region markers (background context)
                let cropStartFraction = CGFloat(startTime / safeDuration)
                let cropEndFraction = CGFloat(endTime / safeDuration)
                
                // Playhead position
                let playFraction = CGFloat(displayTime / safeDuration)
                
                ZStack(alignment: .leading) {
                    // Full track (dimmed)
                    Capsule()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 6)
                    
                    // Crop region background
                    Capsule()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: max(0, (cropEndFraction - cropStartFraction) * width), height: 6)
                        .offset(x: cropStartFraction * width)
                    
                    // Played portion (from song start to playhead)
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: max(0, playFraction * width), height: 6)
                    
                    // Crop boundary markers
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                        .offset(x: cropStartFraction * width - 5)
                    
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                        .offset(x: cropEndFraction * width - 5)
                    
                    // Playhead knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: isSeeking ? 18 : 14, height: isSeeking ? 18 : 14)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: playFraction * width - (isSeeking ? 9 : 7))
                        .animation(.easeOut(duration: 0.1), value: isSeeking)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isSeeking = true
                            let x = max(0, min(value.location.x, width))
                            let time = Double(x / width) * fullDuration
                            // Clamp to crop region
                            seekPosition = max(startTime, min(time, endTime))
                        }
                        .onEnded { _ in
                            // Seek the player
                            if let player = previewPlayer {
                                player.currentTime = seekPosition
                                currentPreviewTime = seekPosition
                            } else {
                                // Start playing from seek position
                                startPreview(from: seekPosition)
                            }
                            isSeeking = false
                        }
                )
            }
            .frame(height: 20)
            .padding(.horizontal, 32)
            
            // Crop region time labels
            HStack {
                Text(formatTime(startTime))
                    .font(.caption2)
                    .foregroundColor(.blue)
                
                Spacer()
                
                Text(formatTime(endTime))
                    .font(.caption2)
                    .foregroundColor(.blue)
            }
            .padding(.horizontal, 32)
        }
    }
    
    // MARK: - Preview Controls
    
    private var previewControls: some View {
        HStack(spacing: 32) {
            // Jump to start
            Button {
                seekToTime(startTime)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
            }
            
            // Rewind 5s
            Button {
                let newTime = max(startTime, displayTime - 5)
                seekToTime(newTime)
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
            }
            
            // Play/Pause
            Button {
                if isPreviewPlaying {
                    pausePreview()
                } else if previewPlayer != nil {
                    resumePreview()
                } else {
                    startPreview(from: currentPreviewTime > startTime ? currentPreviewTime : nil)
                }
            } label: {
                Image(systemName: isPreviewPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.blue)
            }
            
            // Forward 5s
            Button {
                let newTime = min(endTime, displayTime + 5)
                seekToTime(newTime)
            } label: {
                Image(systemName: "goforward.5")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
            }
            
            // Jump to end
            Button {
                seekToTime(max(startTime, endTime - 2))
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
            }
        }
    }
    
    // MARK: - Crop Sliders
    
    private var cropSliders: some View {
        VStack(spacing: 16) {
            // Start time
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "arrow.right.to.line")
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    Text("Start")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    
                    // Tappable time label → text field
                    if isEditingStartTime {
                        HStack(spacing: 4) {
                            TextField("m:ss", text: $startTimeText)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundColor(.blue)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    applyManualTime(text: startTimeText, isStart: true)
                                }
                            Button {
                                applyManualTime(text: startTimeText, isStart: true)
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    } else {
                        Text(formatTime(startTime))
                            .font(.subheadline)
                            .foregroundColor(.blue)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(6)
                            .onTapGesture {
                                startTimeText = formatTime(startTime)
                                isEditingStartTime = true
                                isEditingEndTime = false
                            }
                    }
                }
                Slider(value: $startTime, in: startSliderRange) { editing in
                    if !editing {
                        seekToTime(startTime)
                    }
                }
                .tint(.blue)
            }
            .padding(.horizontal, 32)
            
            // End time
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "arrow.left.to.line")
                        .foregroundColor(.orange)
                        .frame(width: 20)
                    Text("End")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    
                    // Tappable time label → text field
                    if isEditingEndTime {
                        HStack(spacing: 4) {
                            TextField("m:ss", text: $endTimeText)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundColor(.orange)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    applyManualTime(text: endTimeText, isStart: false)
                                }
                            Button {
                                applyManualTime(text: endTimeText, isStart: false)
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    } else {
                        Text(formatTime(endTime))
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(6)
                            .onTapGesture {
                                endTimeText = formatTime(endTime)
                                isEditingEndTime = true
                                isEditingStartTime = false
                            }
                    }
                }
                Slider(value: $endTime, in: endSliderRange) { editing in
                    if !editing {
                        seekToTime(max(startTime, endTime - 3))
                    }
                }
                .tint(.orange)
            }
            .padding(.horizontal, 32)
        }
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button {
                startTime = 0
                endTime = fullDuration
                seekToTime(0)
            } label: {
                Text("Reset")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.gray.opacity(0.15))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
            }
            
            Button {
                applyCrop()
            } label: {
                Text("Apply Crop")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding(.horizontal, 32)
    }
    
    // MARK: - Load Duration
    
    private func loadAudioDuration() {
        isLoading = true
        loadError = nil
        
        guard let url = track.resolvedURL() else {
            loadError = "Could not access the song file."
            isLoading = false
            return
        }
        
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let sampleRate = audioFile.fileFormat.sampleRate
            guard sampleRate > 0 else {
                loadError = "Invalid audio file format."
                isLoading = false
                return
            }
            let duration = Double(audioFile.length) / sampleRate
            
            fullDuration = duration
            startTime = track.cropStartTime ?? 0
            endTime = track.cropEndTime ?? duration
            
            // Clamp to valid range
            startTime = max(0, min(startTime, duration - 0.5))
            endTime = max(startTime + 0.5, min(endTime, duration))
            
            // Set initial playhead at crop start
            currentPreviewTime = startTime
            
            isLoading = false
        } catch {
            loadError = "Unable to read audio: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    // MARK: - Preview Playback
    
    private func startPreview(from seekTime: Double? = nil) {
        guard let url = track.resolvedURL() else { return }
        
        stopPreview()
        _ = url.startAccessingSecurityScopedResource()
        
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            
            let playFromTime = seekTime ?? startTime
            player.currentTime = playFromTime
            player.play()
            
            previewPlayer = player
            isPreviewPlaying = true
            currentPreviewTime = playFromTime
            
            startTimerLoop()
        } catch {
            print("❌ Failed to start preview: \(error)")
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    private func pausePreview() {
        previewPlayer?.pause()
        previewTimer?.invalidate()
        previewTimer = nil
        isPreviewPlaying = false
        // Keep previewPlayer alive so we can resume
    }
    
    private func resumePreview() {
        guard let player = previewPlayer else { return }
        
        // If we're past the end, loop back to start
        if player.currentTime >= endTime {
            player.currentTime = startTime
            currentPreviewTime = startTime
        }
        
        player.play()
        isPreviewPlaying = true
        startTimerLoop()
    }
    
    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewPlaying = false
    }
    
    private func startTimerLoop() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            guard let p = self.previewPlayer else {
                self.pausePreview()
                return
            }
            
            if !p.isPlaying {
                self.pausePreview()
                return
            }
            
            self.currentPreviewTime = p.currentTime
            
            // Loop at end boundary
            if p.currentTime >= self.endTime {
                p.currentTime = self.startTime
                self.currentPreviewTime = self.startTime
            }
        }
    }
    
    private func seekToTime(_ time: Double) {
        let clamped = max(startTime, min(time, endTime))
        currentPreviewTime = clamped
        
        if let player = previewPlayer {
            player.currentTime = clamped
            if !isPreviewPlaying {
                resumePreview()
            }
        } else {
            startPreview(from: clamped)
        }
    }
    
    // MARK: - Apply Crop
    
    private func applyCrop() {
        let hasCrop = startTime > 0.1 || endTime < fullDuration - 0.1
        
        let finalStart: Double? = hasCrop ? startTime : nil
        let finalEnd: Double? = hasCrop ? endTime : nil
        
        // Persist to disk and update all in-memory copies
        downloadManager.updateCropTimes(for: track.id, startTime: finalStart, endTime: finalEnd)
        
        // If this track is currently playing, reload it with the new crop times
        if let current = audioPlayer.currentTrack, current.id == track.id {
            wasMainPlayerPlaying = false
            
            // Create updated track with new crop times
            var updatedTrack = current
            updatedTrack.cropStartTime = finalStart
            updatedTrack.cropEndTime = finalEnd
            
            // Stop current playback and restart with cropped version
            audioPlayer.stop()
            audioPlayer.play(updatedTrack)
        }
        
        stopPreview()
        dismiss()
    }
    
    // MARK: - Helpers
    
    /// Parse "m:ss" or "mm:ss" or just seconds (e.g. "90") into a Double
    private func parseTime(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        
        // Try "m:ss" or "mm:ss" format
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            guard parts.count == 2,
                  let minutes = Int(parts[0]),
                  let seconds = Int(parts[1]),
                  minutes >= 0, seconds >= 0, seconds < 60 else { return nil }
            return Double(minutes * 60 + seconds)
        }
        
        // Try raw seconds
        if let seconds = Double(trimmed), seconds >= 0 {
            return seconds
        }
        
        return nil
    }
    
    private func applyManualTime(text: String, isStart: Bool) {
        guard let parsed = parseTime(text) else {
            // Invalid — reset the text field and dismiss
            if isStart {
                startTimeText = formatTime(startTime)
                isEditingStartTime = false
            } else {
                endTimeText = formatTime(endTime)
                isEditingEndTime = false
            }
            return
        }
        
        if isStart {
            let clamped = max(0, min(parsed, endTime - 0.5))
            startTime = clamped
            isEditingStartTime = false
            seekToTime(startTime)
        } else {
            let clamped = max(startTime + 0.5, min(parsed, fullDuration))
            endTime = clamped
            isEditingEndTime = false
            seekToTime(max(startTime, endTime - 3))
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
