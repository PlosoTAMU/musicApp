import SwiftUI

struct AudioVisualizerView: View {
    let thumbnailImage: UIImage?
    let audioLevels: [Float]
    let averageLevel: Float
    let isPlaying: Bool
    
    @State private var pulseScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // Pulsing thumbnail
            Group {
                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 290, height: 290)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(LinearGradient(
                            colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 290, height: 290)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 80))
                                .foregroundColor(.white.opacity(0.5))
                        )
                }
            }
            .scaleEffect(pulseScale)
            .shadow(color: .black.opacity(0.8), radius: 40 + CGFloat(averageLevel) * 20, y: 12)
            .animation(.easeInOut(duration: 0.1), value: pulseScale)
            
            // Audio bars overlay
            AudioBarsOverlay(levels: audioLevels, isPlaying: isPlaying)
                .frame(width: 290, height: 290)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .onChange(of: averageLevel) { newLevel in
            if isPlaying {
                // Pulse between 0.98 and 1.04 based on audio level
                let targetScale = 1.0 + CGFloat(newLevel) * 0.04
                withAnimation(.easeInOut(duration: 0.1)) {
                    pulseScale = targetScale
                }
            } else {
                pulseScale = 1.0
            }
        }
        .onChange(of: isPlaying) { playing in
            if !playing {
                withAnimation(.easeInOut(duration: 0.3)) {
                    pulseScale = 1.0
                }
            }
        }
    }
}

struct AudioBarsOverlay: View {
    let levels: [Float]
    let isPlaying: Bool
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Semi-transparent overlay for contrast
                Color.black.opacity(isPlaying ? 0.3 : 0.0)
                    .animation(.easeInOut(duration: 0.3), value: isPlaying)
                
                // Bottom bars
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<levels.count, id: \.self) { index in
                        AudioBar(
                            level: CGFloat(levels[index]),
                            isPlaying: isPlaying,
                            index: index
                        )
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

struct AudioBar: View {
    let level: CGFloat
    let isPlaying: Bool
    let index: Int
    
    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            
            // Main bar
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.9),
                            Color.white.opacity(0.6)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 20, height: isPlaying ? max(8, level * 120) : 8)
                .shadow(color: .white.opacity(0.5), radius: 4)
                .animation(
                    .spring(response: 0.15, dampingFraction: 0.6),
                    value: level
                )
            
            // Reflection bar (subtle)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.2))
                .frame(width: 16, height: isPlaying ? max(2, level * 30) : 2)
                .animation(
                    .spring(response: 0.2, dampingFraction: 0.7),
                    value: level
                )
        }
    }
}

// Circular visualizer alternative
struct CircularVisualizerView: View {
    let levels: [Float]
    let isPlaying: Bool
    
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius: CGFloat = min(geometry.size.width, geometry.size.height) / 2 - 20
            
            ZStack {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    visualizerBar(index: index, level: level, center: center, radius: radius)
                }
            }
        }
    }
    
    private func visualizerBar(index: Int, level: Float, center: CGPoint, radius: CGFloat) -> some View {
        let angle = (Double(index) / Double(levels.count)) * 2 * .pi - .pi / 2
        let levelCG = CGFloat(level)
        let barLength = isPlaying ? 20 + levelCG * 60 : 20
        
        return Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.9),
                        Color.white.opacity(0.4)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: barLength, height: 6)
            .cornerRadius(3)
            .shadow(color: .white.opacity(0.4), radius: 3)
            .offset(x: radius + barLength / 2)
            .rotationEffect(.radians(angle))
            .position(center)
            .animation(
                .spring(response: 0.15, dampingFraction: 0.6),
                value: levelCG
            )
    }
}