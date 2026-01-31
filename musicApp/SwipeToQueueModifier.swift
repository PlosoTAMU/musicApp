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
            // Queue indicator background
            if offset > 5 {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 22))
                            .foregroundColor(Color(red: 0.6, green: 1.0, blue: 0.6))
                        Text("Add to Queue")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(red: 0.6, green: 1.0, blue: 0.6))
                    }
                    .frame(width: 100)
                    .padding(.trailing, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.0, green: 0.4, blue: 0.0), Color(red: 0.0, green: 0.5, blue: 0.0)],
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
                        .foregroundColor(.green)
                    Text("Queued")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }
                .padding(.leading, 12)
                .transition(.opacity)
            }
        }
        .clipped()
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