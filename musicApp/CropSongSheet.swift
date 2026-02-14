import SwiftUI
import AVFoundation

struct CropSongSheet: View {
    let track: Track
    let downloadManager: DownloadManager
    let audioPlayer: AudioPlayerManager
    @Environment(\.dismiss) var dismiss
    
    @State private var fullDuration: Double = 0
    @State private var startTime: Double = 0 {
        didSet {
            // Auto-start preview when start time changes
            if !isLoading && loadError == nil && oldValue != startTime {
                startPreview()
            }
        }
    }
    @State private var endTime: Double = 1 // non-zero default avoids invalid slider ranges on init
    @State private var isPreviewPlaying = false
    @State private var currentPreviewTime: Double = 0
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewTimer: Timer?
    @State private var wasMainPlayerPlaying = false
    @State private var isLoading = true
    @State private var loadError: String?
    
    // Safe slider ranges — never produce empty / reversed ranges
    private var startSliderRange: ClosedRange<Double> {
        0...max(endTime - 0.5, 0)
    }
    private var endSliderRange: ClosedRange<Double> {
        let lower = startTime + 0.5
        return lower...max(lower, fullDuration)
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
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text(track.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Text("Full Length: \(formatTime(fullDuration))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("Cropped Length: \(formatTime(max(0, endTime - startTime)))")
                    .font(.headline)
                    .foregroundColor(.blue)
            }
            .padding(.top, 20)
            
            Spacer()
            
            timelineView
            
            // Start time slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "scissors")
                        .foregroundColor(.blue)
                        .frame(width: 24)
                    Text("Start Time")
                        .font(.headline)
                    Spacer()
                    Text(formatTime(startTime))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $startTime, in: startSliderRange)
                    .tint(.blue)
                HStack {
                    Text("0:00").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(fullDuration)).font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 32)
            
            // End time slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "scissors")
                        .foregroundColor(.orange)
                        .frame(width: 24)
                    Text("End Time")
                        .font(.headline)
                    Spacer()
                    Text(formatTime(endTime))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $endTime, in: endSliderRange)
                    .tint(.orange)
                HStack {
                    Text("0:00").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(fullDuration)).font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 32)
            
            // Preview button
            Button {
                if isPreviewPlaying {
                    stopPreview()
                } else {
                    startPreview()
                }
            } label: {
                HStack {
                    Image(systemName: isPreviewPlaying ? "stop.fill" : "play.fill")
                    Text(isPreviewPlaying ? "Stop Preview" : "Preview Cropped Section")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .padding(.horizontal, 32)
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 16) {
                Button {
                    startTime = 0
                    endTime = fullDuration
                } label: {
                    Text("Reset")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }
                
                Button {
                    applyCrop()
                } label: {
                    Text("Apply Crop")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
        }
    }
    
    // MARK: - Timeline View
    
    private var timelineView: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let safeDuration = max(fullDuration, 0.01)
                let startX = CGFloat(startTime / safeDuration) * width
                let endX = CGFloat(endTime / safeDuration) * width
                
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: max(0, endX - startX))
                        .offset(x: startX)
                    
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: 3)
                        .offset(x: startX)
                    
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: 3)
                        .offset(x: max(0, endX - 3))
                    
                    if isPreviewPlaying {
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 2)
                            .offset(x: CGFloat(currentPreviewTime / safeDuration) * width)
                    }
                }
                .contentShape(Rectangle()) // Make entire area tappable
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let tappedX = value.location.x
                            let clampedX = max(0, min(tappedX, width))
                            let tappedTime = Double(clampedX / width) * fullDuration
                            
                            // Clamp to crop boundaries
                            let seekTime = max(startTime, min(tappedTime, endTime))
                            
                            // Update preview player position
                            if let player = previewPlayer {
                                player.currentTime = seekTime
                                currentPreviewTime = seekTime
                            }
                        }
                        .onEnded { value in
                            let tappedX = value.location.x
                            let clampedX = max(0, min(tappedX, width))
                            let tappedTime = Double(clampedX / width) * fullDuration
                            
                            // Clamp to crop boundaries
                            let seekTime = max(startTime, min(tappedTime, endTime))
                            
                            // If not playing, start from this position
                            if previewPlayer == nil {
                                startPreview(from: seekTime)
                            }
                        }
                )
            }
            .frame(height: 60)
            .padding(.horizontal, 32)
            
            HStack {
                Text("0:00").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(formatTime(fullDuration)).font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 32)
        }
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
            
            let capturedStartTime = startTime
            let capturedEndTime = endTime
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                guard let p = self.previewPlayer, p.isPlaying else {
                    self.stopPreview()
                    return
                }
                self.currentPreviewTime = p.currentTime
                if p.currentTime >= capturedEndTime {
                    // Loop back to start
                    p.currentTime = capturedStartTime
                    self.currentPreviewTime = capturedStartTime
                }
            }
        } catch {
            print("❌ Failed to start preview: \(error)")
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewPlaying = false
    }
    
    // MARK: - Apply Crop
    
    private func applyCrop() {
        let hasCrop = startTime > 0.1 || endTime < fullDuration - 0.1
        
        let finalStart: Double? = hasCrop ? startTime : nil
        let finalEnd: Double? = hasCrop ? endTime : nil
        
        downloadManager.updateCropTimes(for: track.id, startTime: finalStart, endTime: finalEnd)
        
        // If this track is currently playing, restart with new crop
        if let current = audioPlayer.currentTrack, current.id == track.id {
            wasMainPlayerPlaying = false // we're restarting — don't also resume old state
            audioPlayer.play(audioPlayer.currentTrack!)
        }
        
        stopPreview()
        dismiss()
    }
    
    // MARK: - Helpers
    
    private func formatTime(_ time: Double) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
