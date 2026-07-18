import Foundation
import Combine
import CryptoKit
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

/// Top-level entry point — shared-secret model.
///
/// The home secret deterministically derives an email/password pair; every
/// device that knows the secret signs into the SAME Firebase account, so all
/// state (session singleton, library, audio) lives under one uid. No pairing,
/// no codes: devices find each other automatically on launch.
///
///   let sync = SyncSessionManager(player: audioPlayer, library: { allTracks })
///   try await sync.connect(secret: "our house phrase")   // once; auto after
///   try await sync.playHere()                             // fenced takeover
@MainActor
final class SyncSessionManager: ObservableObject {

    @Published private(set) var isConnected = false

    let engine: PlaybackSyncEngine
    let coordinator: SessionCoordinator

    private let player: AudioPlayerManager
    private var uid: String = ""
    private(set) var replicator: LibraryReplicator?
    private(set) var playlistSync: PlaylistSync?
    private(set) var settingsSync: SettingsSync?
    private var routeMonitor: RouteHandoffMonitor?

    private static let secretKey = "sync.home.secret"
    private var forwarding = Set<AnyCancellable>()

    init(player: AudioPlayerManager, library: @escaping () -> [Track]) {
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        self.player = player
        self.coordinator = SessionCoordinator(db: Firestore.firestore())
        self.engine = PlaybackSyncEngine(
            player: player,
            coordinator: coordinator,
            resolver: LibraryTrackResolver(library: library)
        )
        // Bluetooth handoff: headphone route changes drive pause/beacon/takeover.
        self.routeMonitor = RouteHandoffMonitor(
            player: player, coordinator: coordinator, engine: engine)

        // Remote mode: while another device owns playback, every local play
        // funnels through play(_:) and is routed to the owner instead of
        // starting audio here; queue/playlist auto-start branches append to
        // the shared queue rather than blasting audio on this device.
        player.playRouter = { [weak engine] track in
            engine?.routePlayIfRemote(track) ?? false
        }
        // "Remote playback" = a live remote owner that is mid-track. A live
        // but IDLE owner must not suppress auto-start: the play(first) that
        // follows goes through playRouter and starts over there — twin of
        // desktop queueMany's sessionIdle branch.
        player.sessionHasRemotePlayback = { [weak engine] in
            (engine?.hasLiveRemoteOwner ?? false) &&
            engine?.coordinator.remote?.playback.track != nil
        }

        // Views observe syncManager; changes actually happen on the nested
        // coordinator/engine. Forward their objectWillChange so role flips and
        // mirror updates re-render SwiftUI without each view observing both.
        coordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarding)
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarding)
    }

    /// Derivation must match desktop/src/firebase.ts byte-for-byte.
    static func deriveCreds(secret: String) -> (email: String, password: String) {
        func sha(_ s: String) -> String {
            SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return (email: "\(sha("pulsor-home-v1|" + secret).prefix(24))@pulsor.app",
                password: sha("pulsor-key-v1|" + secret))
    }

    private var connectRetryTask: Task<Void, Never>?
    private var connectRetryDelay: TimeInterval = 5

    /// Silent auto-connect with a previously saved secret (call at app launch).
    /// Idempotent: safe to call more than once without double-attaching listeners.
    /// A failure (launched offline, flaky network) retries with backoff — sync
    /// must come alive when the network does, not stay dead until relaunch.
    func connectIfConfigured() async {
        guard !isConnected,
              let secret = UserDefaults.standard.string(forKey: Self.secretKey) else { return }
        do {
            try await connect(secret: secret)
            connectRetryDelay = 5
        } catch {
            scheduleConnectRetry()
        }
    }

    private func scheduleConnectRetry() {
        connectRetryTask?.cancel()
        let delay = connectRetryDelay
        connectRetryDelay = min(connectRetryDelay * 2, 60)
        connectRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.connectIfConfigured()
        }
    }

    func connect(secret: String) async throws {
        let creds = Self.deriveCreds(secret: secret)
        do {
            uid = try await Self.withTimeout(label: "Sign-in") {
                try await Auth.auth().signIn(withEmail: creds.email,
                                             password: creds.password).user.uid
            }
        } catch {
            // First device ever creates the home account.
            do {
                uid = try await Self.withTimeout(label: "Sign-in") {
                    try await Auth.auth().createUser(withEmail: creds.email,
                                                     password: creds.password).user.uid
                }
            } catch {
                throw SyncError.corrupt  // surfaced as "could not connect"
            }
        }
        let coordinator = self.coordinator
        let attachUID = uid
        try await Self.withTimeout(label: "Session load") {
            try await coordinator.attach(uid: attachUID)
        }
        replicator?.activate(uid: uid)
        playlistSync?.activate(uid: uid)
        settingsSync?.activate(uid: uid)
        UserDefaults.standard.set(secret, forKey: Self.secretKey)
        isConnected = true
    }

    /// A hung connect stage must surface as an error, not an eternal freeze —
    /// twin of desktop ui.ts's withTimeout. Doesn't cancel the underlying call;
    /// if it completes late, state heals on the next retry/relaunch.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval = 25, label: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SyncError.timeout(label)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Wire two-way playlist replication:
    ///   sync.attachPlaylists(manager: playlistManager,
    ///                        download: { downloadManager.getDownload(byID: $0) })
    func attachPlaylists(manager: PlaylistManager,
                         download: @escaping (UUID) -> Download?) {
        playlistSync = PlaylistSync(db: coordinator.db, manager: manager,
                                    download: download)
        if !uid.isEmpty { playlistSync?.activate(uid: uid) }
    }

    func attachReplication(downloads: AnyPublisher<[Download], Never>,
                           failedDownloads: AnyPublisher<[FailedDownload], Never>,
                           metaChanges: AnyPublisher<Download, Never>,
                           deletions: AnyPublisher<Download, Never>,
                           findDuplicate: @escaping (String) -> Download?,
                           startDownload: @escaping (String, String, DownloadSource, String) -> Void,
                           applyMeta: @escaping (String, TrackMeta) -> Void,
                           applyDeletion: @escaping (String) -> Void) {
        replicator = LibraryReplicator(db: coordinator.db, downloads: downloads,
                                       failedDownloads: failedDownloads,
                                       metaChanges: metaChanges, deletions: deletions,
                                       findDuplicate: findDuplicate, startDownload: startDownload,
                                       applyMeta: applyMeta, applyDeletion: applyDeletion)
        if !uid.isEmpty { replicator?.activate(uid: uid) }
    }

    /// Wire two-way effects-settings sync:
    ///   sync.attachSettings(player: audioPlayer)
    func attachSettings(player: AudioPlayerManager) {
        settingsSync = SettingsSync(db: coordinator.db, player: player)
        if !uid.isEmpty { settingsSync?.activate(uid: uid) }
    }

    /// Handoff: this device becomes the owner and audio continues here.
    func playHere() async throws {
        try await engine.takeOverHere()
    }

    /// Forget the home secret; back to setup.
    func forgetHome() {
        connectRetryTask?.cancel(); connectRetryTask = nil
        UserDefaults.standard.removeObject(forKey: Self.secretKey)
        coordinator.detach()
        isConnected = false
        try? Auth.auth().signOut()
    }
}
