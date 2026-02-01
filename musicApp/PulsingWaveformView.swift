import SwiftUI

struct PulsingWaveformView: View {
    let waveform: [Float]
    let progress: CGFloat
    let pulsePhase: Double
    let isPlaying: Bool
    var vertical: Bool = false
    var flipped: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            if vertical {
                VStack(alignment: .center, spacing: 1) {
                    ForEach(0..<waveform.count, id: \.self) { index in
                        let amplitude = waveform[index]
                        let relativePosition = CGFloat(index) / CGFloat(waveform.count)
                        let isPast = relativePosition < progress
                        let pulseMultiplier = isPlaying ? (1.0 + sin(pulsePhase + Double(index) * 0.3) * 0.3) : 1.0
                        
                        let width = geometry.size.width * CGFloat(amplitude) * CGFloat(pulseMultiplier)
                        
                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                isPast ? 
                                Color.green.opacity(0.8) : 
                                Color.white.opacity(0.5)
                            )
                            .frame(
                                width: max(2, width),
                                height: max(1, geometry.size.height / CGFloat(waveform.count) - 1)
                            )
                            .scaleEffect(x: flipped ? -1 : 1, y: 1)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 1) {
                    ForEach(0..<waveform.count, id: \.self) { index in
                        let amplitude = waveform[index]
                        let relativePosition = CGFloat(index) / CGFloat(waveform.count)
                        let isPast = relativePosition < progress
                        let pulseMultiplier = isPlaying ? (1.0 + sin(pulsePhase + Double(index) * 0.3) * 0.3) : 1.0
                        
                        let height = geometry.size.height * CGFloat(amplitude) * CGFloat(pulseMultiplier)
                        
                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                isPast ? 
                                Color.green.opacity(0.8) : 
                                Color.white.opacity(0.5)
                            )
                            .frame(
                                width: max(1, geometry.size.width / CGFloat(waveform.count) - 1),
                                height: max(2, height)
                            )
                            .scaleEffect(x: 1, y: flipped ? -1 : 1)
                    }
                }
            }
        }
    }
}