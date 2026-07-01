import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

/// Top-level entry point. Owns bootstrap (Firebase config + anonymous auth) and
/// the session lifecycle verbs the UI will eventually call:
///
///   let sync = SyncSessionManager(player: audioPlayer, library: { allTracks })
///   try await sync.bootstrap()
///   let code = try await sync.startSharing()   // device A — shows 6-digit code
///   try await sync.join(code: "042917")        // device B
///   try await sync.playHere()                  // device B takes over playback
///   sync.leave()
@MainActor
final class SyncSessionManager: ObservableObject {

    @Published private(set) var isReady = false
    @Published private(set) var activeCode: String?

    let engine: PlaybackSyncEngine
    let coordinator: SessionCoordinator

    private let player: AudioPlayerManager
    private let pairing: SessionPairing
    private var uid: String = ""

    init(player: AudioPlayerManager, library: @escaping () -> [Track]) {
        // configure() must precede Firestore.firestore(). Idempotent guard lets
        // this coexist with a future configure() call in AppDelegate.
        if FirebaseApp.app() == nil { FirebaseApp.configure() }

        let db = Firestore.firestore()
        // Firestore's own offline mutation queue stays ON for reads (snapshot
        // cache = instant UI on cold start) but all session WRITES go through
        // transactions, which never enqueue offline — the coordinator's outbox
        // is the only replay path, by design.
        self.player = player
        self.coordinator = SessionCoordinator(db: db)
        self.engine = PlaybackSyncEngine(
            player: player,
            coordinator: coordinator,
            resolver: LibraryTrackResolver(library: library)
        )
        self.pairing = SessionPairing(db: db)
    }

    func bootstrap() async throws {
        if let user = Auth.auth().currentUser {
            uid = user.uid
        } else {
            uid = try await Auth.auth().signInAnonymously().user.uid
        }
        isReady = true
    }

    /// Device A: create a session seeded from current local playback, mint a code.
    func startSharing() async throws -> String {
        precondition(isReady, "call bootstrap() first")
        let initial = PlaybackState(
            track: player.currentTrack.map(TrackRef.init),
            isPlaying: player.isPlaying,
            positionMs: Int(player.currentTime * 1000),
            anchorMs: ServerClock.shared.nowMs,
            rateX1000: Int(player.effectivePlaybackSpeed * 1000),
            rev: 1
        )
        let sid = try await coordinator.createSession(
            uid: uid, playback: initial, queue: player.queue.map(TrackRef.init))
        let code = try await pairing.createCode(sessionID: sid, uid: uid)
        activeCode = code
        return code
    }

    /// Device B: redeem code, become a follower (mirror only, no audio).
    func join(code: String) async throws {
        precondition(isReady, "call bootstrap() first")
        let sid = try await pairing.redeem(code: code)
        try await coordinator.joinSession(sid, uid: uid)
    }

    /// Handoff: this device becomes the owner and audio continues here.
    func playHere() async throws {
        try await engine.takeOverHere()
    }

    func leave() {
        coordinator.leave()
        activeCode = nil
    }
}
