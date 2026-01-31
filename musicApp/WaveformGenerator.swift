import Foundation
import Accelerate
import AVFoundation

struct WaveformGenerator {
    
    /// Generate a lightweight waveform (array of amplitude values)
    /// - Parameters:
    ///   - audioURL: URL of the audio file
    ///   - targetSamples: Number of samples (default 100 for lightweight storage)
    /// - Returns: Array of normalized amplitudes [0.0 - 1.0]
    static func generate(from audioURL: URL, targetSamples: Int = 100) -> [Float]? {
        guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
            print("❌ Failed to open audio file")
            return nil
        }
        
        let format = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        
        try? audioFile.read(into: buffer)
        
        guard let channelData = buffer.floatChannelData?[0] else {
            return nil
        }
        
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
        
        // Downsample to targetSamples
        let samplesPerBin = samples.count / targetSamples
        var waveform: [Float] = []
        
        for i in 0..<targetSamples {
            let start = i * samplesPerBin
            let end = min(start + samplesPerBin, samples.count)
            let slice = samples[start..<end]
            
            // Calculate RMS (root mean square) for this bin
            let rms = sqrt(slice.map { $0 * $0 }.reduce(0, +) / Float(slice.count))
            waveform.append(rms)
        }
        
        // Normalize to [0, 1]
        if let maxAmplitude = waveform.max(), maxAmplitude > 0 {
            waveform = waveform.map { $0 / maxAmplitude }
        }
        
        return waveform
    }
    
    /// Save waveform to file
    static func save(_ waveform: [Float], to url: URL) {
        let data = Data(bytes: waveform, count: waveform.count * MemoryLayout<Float>.size)
        try? data.write(to: url)
    }
    
    /// Load waveform from file
    static func load(from url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.withUnsafeBytes {
            Array(UnsafeBufferPointer<Float>(start: $0.baseAddress?.assumingMemoryBound(to: Float.self), count: data.count / MemoryLayout<Float>.size))
        }
    }
}