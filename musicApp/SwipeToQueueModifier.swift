import SwiftUI

struct SwipeToQueueModifier: ViewModifier {
    let onQueue: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isArmed = false        // past the trigger threshold
    @State private var justQueued = false     // confirm state held briefly after commit

    private let threshold: CGFloat = 70       // commit point
    private let restWidth: CGFloat = 100      // open/confirm width (and rubber-band point)

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            actionBackground

            content
                .offset(x: offset)
                .gesture(swipeGesture)
        }
        // Clip to the card shape so the green panel never pokes past the corners.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Reveal behind the row

    private var actionBackground: some View {
        let showCheck = isArmed || justQueued
        return HStack(spacing: 7) {
            Image(systemName: showCheck ? "checkmark.circle.fill" : "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 18, weight: .semibold))
            Text(justQueued ? "Queued" : "Add to Queue")
                .font(Theme.caption(12, weight: .semibold))
        }
        .foregroundColor(Theme.mint)
        // Small pop when armed/confirmed so the state reads visually too.
        .scaleEffect(showCheck ? 1.06 : 1.0)
        .padding(.leading, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: showCheck
                    ? [Color(red: 0.07, green: 0.34, blue: 0.22), Color(red: 0.10, green: 0.44, blue: 0.28)]
                    : [Color(red: 0.05, green: 0.22, blue: 0.15), Color(red: 0.07, green: 0.30, blue: 0.20)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        // Fade the panel in with the swipe instead of popping at a hard cutoff.
        .opacity(Double(min(offset / 40, 1)))
        .animation(.easeOut(duration: 0.18), value: showCheck)
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { g in
                guard !justQueued else { return }   // ignore input during the confirm hold
                let h = g.translation.width
                let v = abs(g.translation.height)
                // Engage only on a clearly horizontal, rightward drag so vertical
                // list scrolling is never stolen.
                guard h > 0, h > v * 1.6 else { return }

                // Track the finger 1:1 up to restWidth, then rubber-band. NO
                // withAnimation here — the offset must equal the finger, not chase it.
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
                    isArmed = false
                    justQueued = true
                    // Snap OPEN to the confirm position (green + "Queued" checkmark),
                    // hold a beat so the action is clearly seen, then close.
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                        offset = restWidth
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                            offset = 0
                        }
                        // Keep the "Queued" label until it's closed.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            justQueued = false
                        }
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        offset = 0
                    }
                    isArmed = false
                }
            }
    }
}

extension View {
    func swipeToQueue(action: @escaping () -> Void) -> some View {
        modifier(SwipeToQueueModifier(onQueue: action))
    }
}
