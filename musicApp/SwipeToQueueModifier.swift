import SwiftUI

struct SwipeToQueueModifier: ViewModifier {
    let onQueue: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isArmed = false        // past the trigger threshold
    @State private var showQueued = false     // brief post-commit confirmation

    private let threshold: CGFloat = 72       // commit point
    private let restWidth: CGFloat = 96       // natural reveal width before rubber-banding

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            actionBackground

            content
                .offset(x: offset)
                .gesture(swipeGesture)

            if showQueued {
                queuedBadge
            }
        }
        // Clip to the card shape so the green panel never pokes past the corners.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Reveal behind the row

    private var actionBackground: some View {
        HStack(spacing: 7) {
            Image(systemName: isArmed ? "checkmark.circle.fill" : "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 18, weight: .semibold))
            Text("Add to Queue")
                .font(Theme.caption(12, weight: .semibold))
        }
        .foregroundColor(Theme.mint)
        // Small pop when it arms so the threshold is felt visually as well as via haptics.
        .scaleEffect(isArmed ? 1.08 : 1.0)
        .padding(.leading, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: isArmed
                    ? [Color(red: 0.07, green: 0.34, blue: 0.22), Color(red: 0.10, green: 0.44, blue: 0.28)]
                    : [Color(red: 0.05, green: 0.22, blue: 0.15), Color(red: 0.07, green: 0.30, blue: 0.20)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        // Fade the panel in with the swipe instead of popping at a hard cutoff.
        .opacity(Double(min(offset / 40, 1)))
        .animation(.easeOut(duration: 0.18), value: isArmed)
    }

    private var queuedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Theme.mint)
            Text("Queued")
                .font(Theme.body(14, weight: .semibold))
                .foregroundColor(Theme.mint)
        }
        .padding(.leading, 18)
        .transition(.opacity)
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { g in
                let h = g.translation.width
                let v = abs(g.translation.height)
                // Engage only on a clearly horizontal, rightward drag so vertical
                // list scrolling is never stolen.
                guard h > 0, h > v * 1.6 else { return }

                // Track the finger 1:1 up to restWidth, then rubber-band. NO
                // withAnimation here — that was the lag/wobble; the offset must
                // equal the finger, not chase it.
                offset = h <= restWidth ? h : restWidth + (h - restWidth) * 0.28

                let armed = offset >= threshold
                if armed != isArmed {
                    isArmed = armed
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .onEnded { g in
                let h = g.translation.width
                let v = abs(g.translation.height)
                let committed = h > v * 1.6 && offset >= threshold

                if committed {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onQueue()
                    showQueued = true
                    // Row springs closed immediately — no awkward hold-open.
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        offset = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation(.easeOut(duration: 0.25)) { showQueued = false }
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        offset = 0
                    }
                }
                isArmed = false
            }
    }
}

extension View {
    func swipeToQueue(action: @escaping () -> Void) -> some View {
        modifier(SwipeToQueueModifier(onQueue: action))
    }
}
