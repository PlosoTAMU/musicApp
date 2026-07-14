import SwiftUI

/// Home-secret pairing + connection status. Replaces the old Sync tab now
/// that sync is always-on in the background — this is only reachable when
/// you need to pair a fresh device or disconnect one.
struct HomeSyncSheet: View {
    @ObservedObject var manager: SyncSessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()

                VStack(spacing: 16) {
                    if manager.coordinator.role == .none {
                        EmptyStateView(
                            icon: "laptopcomputer.and.iphone",
                            title: "Connect your home",
                            message: "Enter the same secret phrase here and on your PC. Devices sharing the secret find each other automatically — playback, queue, and library stay in sync from then on."
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
                    } else {
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Circle().fill(manager.coordinator.isOnline ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                Text(manager.coordinator.isOnline ? "Connected" : "Offline")
                                    .font(Theme.body(15, weight: .semibold))
                            }
                            Text("This device syncs playback, queue, and library with every other device using the same home secret.")
                                .font(Theme.caption(13))
                                .foregroundColor(Theme.boneDim)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }

                        Spacer().frame(height: 12)

                        Button("Forget Home", role: .destructive) {
                            manager.forgetHome()
                            dismiss()
                        }
                        .font(Theme.body(15, weight: .semibold))
                    }

                    if let error {
                        Text(error).font(Theme.caption(12)).foregroundColor(.red)
                    }
                }
                .padding(.vertical, 24)
            }
            .navigationTitle("Home Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .buttonStyle(ChipButtonStyle())
                }
            }
        }
    }
}
