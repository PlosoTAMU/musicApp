import SwiftUI
import AVFoundation

struct CropSongSheet: View {
    let track: Track
    let downloadManager: DownloadManager
    let audioPlayer: AudioPlayerManager
    @Environment(\.dismiss) var dismiss
    
    @State private var fullDuration: Double = 0
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0
    @State private var isPlaying = false
    @State private var currentPreviewTime: Double = 0
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewTimer: Timer?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Preview section
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
                    
                    Text("Cropped Length: \(formatTime(endTime - startTime))")
                        .font(.headline)
                        .foregroundColor(.blue)
                }
                .padding(.top, 20)
                
                Spacer()
                
                // Visual timeline
                VStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        // Full timeline
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 60)
                        
                        // Cropped region
                        GeometryReader { geometry in
                            let width = geometry.size.width
                            let startX = CGFloat(startTime / fullDuration) * width
                            let endX = CGFloat(endTime / fullDuration) * width
                            
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue.opacity(0.3))
                                .frame(width: endX - startX)
                                .offset(x: startX)
                            
                            // Start marker
                            Rectangle()
                                .fill(Color.blue)
                                .frame(width: 3)
                                .offset(x: startX)
                            
                            // End marker
                            Rectangle()
                                .fill(Color.blue)
                                .frame(width: 3)
                                .offset(x: endX)
                            
                            // Playhead during preview
                            if isPlaying {
                                Rectangle()
                                    .fill(Color.red)
                                    .frame(width: 2)
                                    .offset(x: CGFloat(currentPreviewTime / fullDuration) * width)
                            }
                        }
                        .frame(height: 60)
                    }
                    .padding(.horizontal, 32)
                    
                    // Time labels
                    HStack {
                        Text("0:00")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTime(fullDuration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 32)
                }
                
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
                    
                    Slider(value: $startTime, in: 0...max(0, endTime - 1)) {
                        Text("Start")
                    } minimumValueLabel: {
                        Text("0:00")
                            .font(.caption2)
                    } maximumValueLabel: {
                        Text(formatTime(endTime))
                            .font(.caption2)
                    }
                    .tint(.blue)
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
                    
                    Slider(value: $endTime, in: max(startTime + 1, 0)...fullDuration) {
                        Text("End")
                    } minimumValueLabel: {
                        Text(formatTime(startTime))
                            .font(.caption2)
                    } maximumValueLabel: {
                        Text(formatTime(fullDuration))
                            .font(.caption2)
                    }
                    .tint(.orange)
                }
                .padding(.horizontal, 32)
                
                // Preview button
                Button {
                    if isPlaying {
                        stopPreview()
                    } else {
                        startPreview()
                    }
                } label: {
                    HStack {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        Text(isPlaying ? "Stop Preview" : "Preview Cropped Section")
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
                        // Reset to no crop
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
            loadAudioDuration()
        }
        .onDisappear {
            stopPreview()
        }
    }
    
    private func loadAudioDuration() {
        guard let url = track.resolvedURL() else { return }
        
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let sampleRate = audioFile.fileFormat.sampleRate
            let frameCount = Double(audioFile.length)
            fullDuration = frameCount / sampleRate
            
            // Initialize with existing crop times or full duration
            startTime = track.cropStartTime ?? 0
            endTime = track.cropEndTime ?? fullDuration
        } catch {
            print("❌ Failed to load audio file: \(error)")
            fullDuration = 0
            startTime = 0
            endTime = 0
        }
    }
    
    private func startPreview() {
        guard let url = track.resolvedURL() else { return }
        
        do {
            stopPreview()
            
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.currentTime = startTime
            previewPlayer?.play()
            isPlaying = true
            currentPreviewTime = startTime
            
            // Update playhead and stop at end time
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] _ in
                guard let player = previewPlayer else {
                    stopPreview()
                    return
                }
                
                currentPreviewTime = player.currentTime
                
                if player.currentTime >= endTime || !player.isPlaying {
                    stopPreview()
                }
            }
        } catch {
            print("❌ Failed to start preview: \(error)")
            isPlaying = false
        }
    }
    
    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        previewTimer?.invalidate()
        previewTimer = nil
        isPlaying = false
    }
    
    private func applyCrop() {
        // Determine if crop is meaningful (not just 0 to full duration)
        let hasCrop = startTime > 0.1 || endTime < fullDuration - 0.1
        
        let finalStartTime: Double? = hasCrop ? startTime : nil
        let finalEndTime: Double? = hasCrop ? endTime : nil
        
        downloadManager.updateCropTimes(for: track.id, startTime: finalStartTime, endTime: finalEndTime)
        
        // If this track is currently playing, restart it with new crop
        if audioPlayer.currentTrack?.id == track.id {
            audioPlayer.play(audioPlayer.currentTrack!)
        }
        
        stopPreview()
        dismiss()
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
