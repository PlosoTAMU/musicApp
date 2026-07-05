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
    }

    /// Derivation must match desktop/src/firebase.ts byte-for-byte.
    static func deriveCreds(secret: String) -> (email: String, password: String) {
        func sha(_ s: String) -> String {
            SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return (email: "\(sha("pulsor-home-v1|" + secret).prefix(24))@pulsor.app",
                password: sha("pulsor-key-v1|" + secret))
    }

    /// Silent auto-connect with a previously saved secret (call at app launch).
    /// Idempotent: ContentView's launch task and SyncPanelView's .task can both
    /// fire without double-attaching listeners.
    func connectIfConfigured() async {
        guard !isConnected,
              let secret = UserDefaults.standard.string(forKey: Self.secretKey) else { return }
        try? await connect(secret: secret)
    }

    func connect(secret: String) async throws {
        let creds = Self.deriveCreds(secret: secret)
        do {
            uid = try await Auth.auth().signIn(withEmail: creds.email,
                                               password: creds.password).user.uid
        } catch {
            // First device ever creates the home account.
            do {
                uid = try await Auth.auth().createUser(withEmail: creds.email,
                                                       password: creds.password).user.uid
            } catch {
                throw SyncError.corrupt  // surfaced as "could not connect"
            }
        }
        try await coordinator.attach(uid: uid)
        replicator?.activate(uid: uid)
        playlistSync?.activate(uid: uid)
        settingsSync?.activate(uid: uid)
        UserDefaults.standard.set(secret, forKey: Self.secretKey)
        isConnected = true
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

    /// Wire the upload/download pipeline to DownloadManager:
    ///   sync.attachReplication(
    ///     downloads: downloadManager.$downloads.eraseToAnyPublisher(),
    ///     failedDownloads: downloadManager.$failedDownloads.eraseToAnyPublisher(),
    ///     findDuplicate: { yt in downloadManager.findDuplicateByVideoID(videoID: yt, source: .youtube) },
    ///     startDownload: { url, yt, source, title in
    ///       downloadManager.startBackgroundDownload(url: url, videoID: yt, source: source, title: title)
    ///     })
    func attachReplication(downloads: AnyPublisher<[Download], Never>,
                           failedDownloads: AnyPublisher<[FailedDownload], Never>,
                           findDuplicate: @escaping (String) -> Download?,
                           startDownload: @escaping (String, String, DownloadSource, String) -> Void) {
        replicator = LibraryReplicator(db: coordinator.db, downloads: downloads,
                                       failedDownloads: failedDownloads,
                                       findDuplicate: findDuplicate, startDownload: startDownload)
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
        UserDefaults.standard.removeObject(forKey: Self.secretKey)
        coordinator.detach()
        isConnected = false
        try? Auth.auth().signOut()
    }
}
