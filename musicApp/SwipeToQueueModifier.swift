import SwiftUI

struct SwipeToQueueModifier: ViewModifier {
    let onQueue: () -> Void
    @State private var offset: CGFloat = 0
    @State private var showQueueAdded = false
    @State private var isSwiping = false
    
    private let threshold: CGFloat = 60
    private let maxOffset: CGFloat = 120
    
    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            // Queue indicator background (mint = queue semantics)
            if offset > 5 {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(Theme.mint)
                        Text("Add to Queue")
                            .font(Theme.caption(11, weight: .semibold))
                            .foregroundColor(Theme.mint)
                    }
                    .frame(width: 100)
                    .padding(.trailing, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.05, green: 0.22, blue: 0.15),
                            Color(red: 0.07, green: 0.30, blue: 0.20)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
            
            content
                .offset(x: offset)
                .gesture(swipeGesture)
            
            if showQueueAdded {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.mint)
                    Text("Queued")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundColor(Theme.mint)
                }
                .padding(.leading, 12)
                .transition(.opacity)
            }
        }
        // Clip to the same rounded shape as the card rows so the mint
        // panel never pokes out past the row corners.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { gesture in
                let horizontal = gesture.translation.width
                let vertical = abs(gesture.translation.height)
                
                if horizontal > 0 && horizontal > vertical * 2.5 {
                    isSwiping = true
                    withAnimation(.interactiveSpring()) {
                        offset = min(horizontal, maxOffset)
                    }
                }
            }
            .onEnded { gesture in
                let horizontal = gesture.translation.width
                let vertical = abs(gesture.translation.height)
                
                if horizontal > vertical * 2.5 {
                    if horizontal > threshold {
                        triggerQueue()
                    } else {
                        resetSwipe()
                    }
                } else {
                    resetSwipe()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isSwiping = false
                }
            }
    }
    
    private func triggerQueue() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onQueue()
        showQueueAdded = true
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            offset = maxOffset
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            resetSwipe()
            showQueueAdded = false
        }
    }
    
    private func resetSwipe() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            offset = 0
        }
    }
}

extension View {
    func swipeToQueue(action: @escaping () -> Void) -> some View {
        modifier(SwipeToQueueModifier(onQueue: action))
    }
}
