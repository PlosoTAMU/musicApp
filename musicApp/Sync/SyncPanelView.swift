import SwiftUI

/// iPhone-side sync panel — shared-secret model. First run: enter the home
/// secret once; every launch after that connects silently.
struct SyncPanelView: View {
    @ObservedObject var manager: SyncSessionManager
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var engine: PlaybackSyncEngine
    @State private var error: String?

    init(manager: SyncSessionManager) {
        self.manager = manager
        self.coordinator = manager.coordinator
        self.engine = manager.engine
    }

    var body: some View {
        Group {
            if coordinator.role == .none {
                SecretSetupPanel(manager: manager, error: $error)
            } else {
                SessionView(manager: manager, coordinator: coordinator,
                            engine: engine, error: $error)
            }
        }
        .task { await manager.connectIfConfigured() }
        .alert("Sync Error", isPresented: .init(
            get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}

// MARK: - First-run: home secret

struct SecretSetupPanel: View {
    @ObservedObject var manager: SyncSessionManager
    @Binding var error: String?
    @State private var secret = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 16) {
            EmptyStateView(
                icon: "laptopcomputer.and.iphone",
                title: "Connect your home",
                message: "Enter the same secret phrase here and on your PC. Devices sharing the secret find each other automatically."
            )

            SecureField("Home secret phrase", text: $secret)
                .textContentType(.password)
                .multilineTextAlignment(.center)
                .font(Theme.body(16))
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Theme.smoke))
                .overlay(Capsule().strokeBorder(Theme.seam, lineWidth: 1))
                .padding(.horizontal, 32)

            Button(busy ? "Connecting…" : "Connect") {
                guard secret.count >= 4 else {
                    error = "Secret must be at least 4 characters"; return
                }
                busy = true
                Task {
                    defer { busy = false }
                    do { try await manager.connect(secret: secret) }
                    catch { self.error = "Could not connect — check the secret and try again" }
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(busy || secret.count < 4)
            .padding(.horizontal, 32)
        }
        .padding(.vertical, 24)
    }
}

// MARK: - Session: handover, mirror, command routing

struct SessionView: View {
    @ObservedObject var manager: SyncSessionManager
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var engine: PlaybackSyncEngine
    @Binding var error: String?

    @State private var dragMs: Double?     // in-flight scrub, not yet committed
    @State private var takingOver = false

    private var playback: PlaybackState? { coordinator.remote?.playback }

    var body: some View {
        VStack(spacing: 12) {
            header
            nowPlaying
            transport
            queueList
            Button("Forget home", role: .destructive) { manager.forgetHome() }
                .font(Theme.caption(12))
        }
        .padding()
    }

    private var header: some View {
        HStack {
            Text(coordinator.role.isOwner ? "PLAYING HERE" : "REMOTE")
                .font(.caption.bold())
            Circle().fill(coordinator.isOnline ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            if !coordinator.role.isOwner,
               let r = coordinator.remote, !r.isIdle, r.leaseExpired {
                Text("owner offline").font(.caption).foregroundColor(.orange)
            }
            Spacer()
            if !coordinator.role.isOwner {
                Button(takingOver ? "…" : "▶ Play Here") {
                    takingOver = true
                    Task {
                        defer { takingOver = false }
                        do { try await manager.playHere() }
                        catch { self.error = "Takeover failed: \(error.localizedDescription)" }
                    }
                }
                .disabled(takingOver || !coordinator.isOnline)
            }
        }
    }

    private var nowPlaying: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(alignment: .leading, spacing: 4) {
                Text(playback?.track?.name ?? "Nothing playing").font(.headline)

                if let pb = playback, pb.durationMs > 0 {
                    // Computed on demand each tick — this TimelineView already
                    // re-invokes every 0.5s while (and only while) visible, so
                    // no separate always-on timer/published value is needed.
                    let live = Double(pb.positionMs(atServerMs: ServerClock.shared.nowMs))
                    let dur = Double(pb.durationMs)

                    Slider(
                        value: .init(get: { min(dragMs ?? live, dur) },
                                     set: { dragMs = $0 }),
                        in: 0...dur
                    ) { editing in
                        guard !editing, let target = dragMs else { return }
                        engine.requestSeek(ms: Int(target))
                        dragMs = nil
                    }
                    HStack {
                        Text(Self.mmss(dragMs ?? live))
                        Spacer()
                        Text(Self.mmss(dur))
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 24) {
            Button { engine.requestPrevious() } label: { Image(systemName: "backward.fill") }
            Button {
                playback?.isPlaying == true ? engine.requestPause() : engine.requestPlay()
            } label: {
                Image(systemName: playback?.isPlaying == true ? "pause.fill" : "play.fill")
            }
            Button { engine.requestNext() } label: { Image(systemName: "forward.fill") }
        }
        .font(.title2)
    }

    private var queueList: some View {
        List(coordinator.remote?.queue ?? [], id: \.id) { ref in
            HStack {
                Text(ref.name)
                Spacer()
                if engine.ghostQueue.contains(where: { $0.id == ref.id }) {
                    Label("not on this device", systemImage: "icloud.slash")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .frame(minHeight: 120)
    }

    private static func mmss(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
