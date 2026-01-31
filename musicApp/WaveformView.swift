import SwiftUI

struct WaveformView: View {
    let waveform: [Float]
    let barCount: Int
    let color: Color
    
    init(waveform: [Float], barCount: Int = 50, color: Color = .white) {
        self.waveform = waveform
        self.barCount = barCount
        self.color = color
    }
    
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let amplitude = getAmplitude(for: index)
                    let height = geometry.size.height * CGFloat(amplitude)
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.7 + Double(amplitude) * 0.3))
                        .frame(width: max(2, geometry.size.width / CGFloat(barCount) - 2), height: max(4, height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private func getAmplitude(for index: Int) -> Float {
        guard !waveform.isEmpty else { return 0.2 }
        let waveformIndex = Int(Float(index) / Float(barCount) * Float(waveform.count))
        return waveform[min(waveformIndex, waveform.count - 1)]
    }
}