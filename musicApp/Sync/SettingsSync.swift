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
/// `bypass` (iOS effectsBypass / desktop fx.bypass) is part of the doc — it is
/// OPTIONAL on the wire, and absent means "written by a pre-M10 client", read
/// as false. Without it a bypassed device published slider values it wasn't
/// hearing and a non-bypassed device applied them audibly, contradicting
/// PlaybackState.rate, which IS bypass-adjusted (sync-audit-4 M10).
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
    private var lastAppliedPitch: Double?
    private var lastAppliedBypass: Bool?

    /// True when THIS device owns the session's audio. Decides whether a
    /// remote's values are persisted into the current track's memory (see
    /// applyRemote). Injected so this class stays independent of the
    /// coordinator; SyncSessionManager wires it.
    private let ownsAudio: () -> Bool

    init(db: Firestore, player: AudioPlayerManager, ownsAudio: @escaping () -> Bool) {
        self.db = db
        self.player = player
        self.ownsAudio = ownsAudio

        // effectsBypass rides along (sync-audit-4 M10): publishing the sliders
        // without the master switch meant a bypassed device pushed values it
        // wasn't hearing and the other device played them — and they
        // contradicted PlaybackState.rate, which IS bypass-adjusted.
        //
        // Pitch rides along too. It was the one effect neither side published
        // ("reverb, pitch and bass don't sync") — nested CombineLatest because
        // CombineLatest4 is the widest Combine ships.
        Publishers.CombineLatest(
            Publishers.CombineLatest4(player.$playbackSpeed, player.$bassBoost,
                                      player.$reverbAmount, player.$effectsBypass),
            player.$pitchShift)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] core, pitch in
                let (speed, bass, reverb, bypass) = core
                self?.push(speed: speed, bass: bass, reverb: reverb, pitch: pitch, bypass: bypass)
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

    /// Detach from the current home — otherwise `forgetHome` leaves this
    /// listener applying a forgotten home's effects (sync-audit-4 M9).
    /// lastApplied* is cleared so reconnecting re-pushes local values instead
    /// of believing the new home already has them.
    func deactivate() {
        listener?.remove(); listener = nil
        uid = ""
        lastAppliedSpeed = nil
        lastAppliedBass = nil
        lastAppliedReverb = nil
        lastAppliedPitch = nil
        lastAppliedBypass = nil
    }

    private var docRef: DocumentReference {
        db.collection("users").document(uid).collection("sync").document("settings")
    }

    private func push(speed: Double, bass: Double, reverb: Double, pitch: Double, bypass: Bool) {
        guard !uid.isEmpty else { return }
        if speed == lastAppliedSpeed, bass == lastAppliedBass,
           reverb == lastAppliedReverb, pitch == lastAppliedPitch,
           bypass == lastAppliedBypass { return }

        // Update lastApplied* to track "last state we believe Firestore already has"
        lastAppliedSpeed = speed
        lastAppliedBass = bass
        lastAppliedReverb = reverb
        lastAppliedPitch = pitch
        lastAppliedBypass = bypass

        let doc: [String: Any] = [
            "speed": speed, "bassDb": bass, "reverbPct": reverb, "pitchSt": pitch,
            "bypass": bypass,
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
        // Absent = written by a client from before pitch synced; read as 0.
        let pitch = (d["pitchSt"] as? NSNumber)?.doubleValue ?? 0
        let clampedPitch = min(max(pitch, -12), 12)
        // Absent = written by a pre-M10 client, which had no concept of the
        // switch and whose values were being applied as if active.
        let bypass = d["bypass"] as? Bool ?? false

        lastAppliedSpeed = clampedSpeed
        lastAppliedBass = clampedBass
        lastAppliedReverb = clampedReverb
        lastAppliedPitch = clampedPitch
        lastAppliedBypass = bypass

        // Per-track memory (didSet → saveCurrentTrackSettings):
        //  - FOLLOWER: suppress (sync-audit-3.md F7). The values describe the
        //    OWNER's playback, not intent for whatever track is loaded here;
        //    persisting them corrupted that track's per-file memory.
        //  - OWNER: persist. A remote's slider drag is exactly a local drag of
        //    the song playing here and must stick the same way. Suppressing it
        //    meant the next track change restored the OLD memory and published
        //    it, silently undoing the other device's change — which read as
        //    "reverb/bass don't sync".
        player.isApplyingRemoteSettings = !ownsAudio()
        defer { player.isApplyingRemoteSettings = false }
        player.playbackSpeed = clampedSpeed
        player.bassBoost = clampedBass
        player.reverbAmount = clampedReverb
        player.pitchShift = clampedPitch
        player.effectsBypass = bypass
    }
}
