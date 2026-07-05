import Foundation
import Combine
import FirebaseFirestore

/// Two-way effects-settings sync — users/{uid}/sync/settings (singleton
/// doc, same doc family as the session/playlist docs). Twin of
/// desktop/src/settingsSync.ts — FIELD NAMES ARE THE CONTRACT.
///
/// LWW is Firestore's own snapshot ordering (same as SessionState/
/// CloudPlaylist) — `at` (ServerClock ms) is carried for parity/debugging,
/// not compared client-side. `updatedBy` filters same-device echo.
///
/// Speed and bass share units with desktop as-is (multiplier, dB). Reverb is
/// wired 0-100% on the wire; desktop's internal `fx.reverb` is a 0-1
/// fraction, converted at its own sync boundary.
///
/// iOS persists these per-track (`AudioPlayerManager.TrackSettings`), so
/// switching tracks changes the published values as a side effect — that's
/// intentional here: it syncs "whichever effective settings are currently
/// audible", the same way playback state syncs the currently-playing track.
@MainActor
final class SettingsSync {

    private let db: Firestore
    private let player: AudioPlayerManager
    private var bag = Set<AnyCancellable>()
    private var listener: ListenerRegistration?
    private var uid = ""

    // Last values WE applied from a remote snapshot. Lets the local publish
    // sink tell "user moved a slider" apart from "assigning the remote value
    // re-fired @Published" without a timing flag — the publish side is
    // debounced, so a flag would have cleared by the time it fires.
    private var lastAppliedSpeed: Double?
    private var lastAppliedBass: Double?
    private var lastAppliedReverb: Double?

    init(db: Firestore, player: AudioPlayerManager) {
        self.db = db
        self.player = player

        Publishers.CombineLatest3(player.$playbackSpeed, player.$bassBoost, player.$reverbAmount)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] speed, bass, reverb in
                self?.push(speed: speed, bass: bass, reverb: reverb)
            }
            .store(in: &bag)
    }

    func activate(uid: String) {
        self.uid = uid
        listener?.remove()
        listener = docRef.addSnapshotListener { [weak self] snap, _ in
            guard let snap else { return }
            Task { @MainActor in self?.applyRemote(snap) }
        }
    }

    private var docRef: DocumentReference {
        db.collection("users").document(uid).collection("sync").document("settings")
    }

    private func push(speed: Double, bass: Double, reverb: Double) {
        guard !uid.isEmpty else { return }
        if speed == lastAppliedSpeed && bass == lastAppliedBass && reverb == lastAppliedReverb { return }
        let doc: [String: Any] = [
            "speed": speed, "bassDb": bass, "reverbPct": reverb,
            "updatedBy": SyncDevice.id, "at": ServerClock.shared.nowMs,
        ]
        Task { try? await docRef.setData(doc) }
    }

    private func applyRemote(_ snap: DocumentSnapshot) {
        guard let d = snap.data(),
              let by = d["updatedBy"] as? String, by != SyncDevice.id,
              let speed = (d["speed"] as? NSNumber)?.doubleValue,
              let bass = (d["bassDb"] as? NSNumber)?.doubleValue,
              let reverb = (d["reverbPct"] as? NSNumber)?.doubleValue else { return }

        let clampedSpeed = min(max(speed, 0.5), 2.0)
        let clampedBass = min(max(bass, -10), 20)
        let clampedReverb = min(max(reverb, 0), 100)

        lastAppliedSpeed = clampedSpeed
        lastAppliedBass = clampedBass
        lastAppliedReverb = clampedReverb

        player.playbackSpeed = clampedSpeed
        player.bassBoost = clampedBass
        player.reverbAmount = clampedReverb
    }
}
