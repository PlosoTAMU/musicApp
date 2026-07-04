import Foundation
import AVFoundation

/// The Bluetooth half of "switch the headphones, switch the playback".
///
/// Owner side: headphones disconnect → pause IMMEDIATELY and post a 60 s
/// handoff beacon on the session doc. If they reconnect to this same phone
/// inside the window, resume and clear the beacon.
///
/// Follower side: an audio route appearing while another device's beacon is
/// live means the user just walked their headphones over here → fenced
/// auto-takeover with forcePlay (the old owner paused on disconnect, so the
/// session reads "paused"; the intent is continuation).
@MainActor
final class RouteHandoffMonitor {

    private let player: AudioPlayerManager
    private let coordinator: SessionCoordinator
    private let engine: PlaybackSyncEngine

    /// We paused because the route died — the flag that separates "resume on
    /// reconnect" from "user paused on purpose, leave it alone".
    private var pausedByRouteLoss = false
    private var observer: NSObjectProtocol?

    init(player: AudioPlayerManager, coordinator: SessionCoordinator,
         engine: PlaybackSyncEngine) {
        self.player = player
        self.coordinator = coordinator
        self.engine = engine

        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            Task { @MainActor in self?.handle(reason) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func handle(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones left. Pause instantly (spec: no speaker blast), then
            // beacon so whichever device they land on can pick playback up.
            guard coordinator.role.isOwner, player.isPlaying else { return }
            player.pause()
            pausedByRouteLoss = true
            Task { await coordinator.postHandoff() }

        case .newDeviceAvailable:
            if pausedByRouteLoss, coordinator.role.isOwner {
                // Same phone got the headphones back → just resume.
                pausedByRouteLoss = false
                player.resume()
                Task { await coordinator.clearHandoff() }
            } else if !coordinator.role.isOwner,
                      let s = coordinator.remote,
                      s.handoffActive(nowMs: ServerClock.shared.nowMs) {
                // Headphones hopped from another device to this phone.
                Task { try? await engine.takeOverHere(forcePlay: true) }
            }

        default:
            break
        }
    }
}
