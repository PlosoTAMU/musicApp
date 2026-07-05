import Foundation
import FirebaseFirestore

// MARK: - Errors

enum SyncError: Error {
    case fenced        // our epoch is stale — another device took over
    case noSession
    case corrupt       // remote doc failed to parse
    case badCode       // pairing code invalid/expired
    case codeCollision
    case queueStale    // offline queue replay lost to a newer edit
}

// MARK: - Device identity (stable per install)

enum SyncDevice {
    static let id: String = {
        let key = "sync.device.id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
}

// MARK: - Cross-device track identity
// Files are local — UUIDs only match if both devices imported the same library.
// Resolution chain: UUID → YouTube videoId → (name, folder) → name.

struct TrackRef: Equatable {
    let id: UUID
    let name: String
    let folder: String
    let ytID: String?

    /// Injectable lookup for the strongest identity key. Wire this to
    /// DownloadManager at startup — `Download.videoID` is persisted per file:
    ///   TrackRef.ytIDProvider = { t in downloadManager.downloads.first { $0.id == t.id }?.videoID }
    /// Falls back to the filename heuristic when unset.
    static var ytIDProvider: ((Track) -> String?)?

    init(id: UUID, name: String, folder: String, ytID: String?) {
        self.id = id; self.name = name; self.folder = folder; self.ytID = ytID
    }

    init(track: Track) {
        self.init(id: track.id, name: track.name, folder: track.folderName,
                  ytID: TrackRef.ytIDProvider?(track) ?? TrackRef.extractYTID(from: track.url))
    }

    /// Best-effort: yt-dlp default template embeds "[<11-char id>]" in the filename.
    /// This app's pipeline renames to the title, so this usually returns nil today —
    /// kept as the strongest key when available.
    static func extractYTID(from url: URL) -> String? {
        let base = url.deletingPathExtension().lastPathComponent
        guard let open = base.lastIndex(of: "["),
              let close = base.lastIndex(of: "]"), open < close else { return nil }
        let candidate = String(base[base.index(after: open)..<close])
        return candidate.count == 11 ? candidate : nil
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["id": id.uuidString, "name": name, "folder": folder]
        if let ytID { d["yt"] = ytID }
        return d
    }

    init?(dict: [String: Any]) {
        guard let idStr = dict["id"] as? String, let uuid = UUID(uuidString: idStr),
              let name = dict["name"] as? String,
              let folder = dict["folder"] as? String else { return nil }
        self.init(id: uuid, name: name, folder: folder, ytID: dict["yt"] as? String)
    }
}

// MARK: - Cloud library metadata (LINK-SYNC doc shape)
// Wire-format twin of desktop/src/protocol.ts's TrackMeta. Written by
// LibraryReplicator's upload side; read by both the upload-dedupe check and
// the down-sync listener.
struct TrackMeta {
    let name: String
    let folder: String
    let yt: String?
    let ext: String
    let by: String

    init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String,
              let folder = dict["folder"] as? String,
              let ext = dict["ext"] as? String,
              let by = dict["by"] as? String else { return nil }
        self.name = name; self.folder = folder; self.ext = ext; self.by = by
        self.yt = dict["yt"] as? String
    }
}

protocol TrackResolving {
    func resolve(_ ref: TrackRef) -> Track?
}

struct LibraryTrackResolver: TrackResolving {
    /// Closure so the resolver always sees the live library, not a snapshot.
    let library: () -> [Track]

    func resolve(_ ref: TrackRef) -> Track? {
        let lib = library()
        if let t = lib.first(where: { $0.id == ref.id }) { return t }
        if let yt = ref.ytID,
           let t = lib.first(where: { TrackRef.extractYTID(from: $0.url) == yt }) { return t }
        if let t = lib.first(where: { $0.name == ref.name && $0.folderName == ref.folder }) { return t }
        return lib.first(where: { $0.name == ref.name })
    }
}

// MARK: - Playback state (the reconciled truth)

struct PlaybackState: Equatable {
    var track: TrackRef?
    var isPlaying: Bool
    var positionMs: Int      // media position at the anchor instant
    var anchorMs: Int        // ServerClock ms when positionMs was true
    var rateX1000: Int       // effective playback rate ×1000 (affects extrapolation)
    var durationMs: Int      // cropped track length — follower progress denominator
    var rev: Int             // monotonic per-epoch; (epoch, rev) totally orders writes

    static let empty = PlaybackState(track: nil, isPlaying: false, positionMs: 0,
                                     anchorMs: 0, rateX1000: 1000, durationMs: 0, rev: 0)

    /// Follower-side extrapolation — the reason progress_ms never needs streaming.
    func positionMs(atServerMs now: Int) -> Int {
        guard isPlaying else { return positionMs }
        let elapsed = max(0, now - anchorMs)
        return positionMs + Int(Double(elapsed) * Double(rateX1000) / 1000.0)
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["playing": isPlaying, "pos": positionMs,
                                "anchor": anchorMs, "rate": rateX1000,
                                "dur": durationMs, "rev": rev]
        if let track { d["track"] = track.dict }
        return d
    }

    init(track: TrackRef?, isPlaying: Bool, positionMs: Int, anchorMs: Int,
         rateX1000: Int, durationMs: Int, rev: Int) {
        self.track = track; self.isPlaying = isPlaying; self.positionMs = positionMs
        self.anchorMs = anchorMs; self.rateX1000 = rateX1000
        self.durationMs = durationMs; self.rev = rev
    }

    init?(dict: [String: Any]?) {
        guard let d = dict,
              let playing = d["playing"] as? Bool,
              let pos = d["pos"] as? Int,
              let anchor = d["anchor"] as? Int,
              let rate = d["rate"] as? Int,
              let rev = d["rev"] as? Int else { return nil }
        self.init(track: (d["track"] as? [String: Any]).flatMap(TrackRef.init(dict:)),
                  isPlaying: playing, positionMs: pos, anchorMs: anchor,
                  rateX1000: rate, durationMs: d["dur"] as? Int ?? 0, rev: rev)
    }
}

// MARK: - Session document

// Shared-secret model: the secret derives one Firebase account, so every
// device shares ONE uid. The session is a singleton doc at
// users/{uid}/sync/session. Device-level ownership stays epoch-fenced.
struct SessionState {

    /// Bluetooth-handoff beacon: the owner's headphones just disconnected. Any
    /// device that gains an audio output within the window auto-takes-over —
    /// "switch the Bluetooth connection to switch playback".
    struct Handoff {
        let by: String    // device that lost its route
        let atMs: Int     // ServerClock ms when it happened
    }

    var epoch: Int
    var ownerDeviceID: String   // "" = idle, nobody owns playback yet
    var leaseMs: Int            // last lease renewal (ServerClock ms)
    var playback: PlaybackState
    var queue: [TrackRef]
    var queueVersion: Int
    var updatedBy: String       // device id of last writer — anti-echo
    var handoff: Handoff?

    static let leaseTTLMs = 45_000
    static let handoffWindowMs = 60_000

    var isIdle: Bool { ownerDeviceID.isEmpty }
    var leaseExpired: Bool { ServerClock.shared.nowMs > leaseMs + Self.leaseTTLMs }

    /// True when ANOTHER device's headphones dropped recently enough that an
    /// audio-output gain HERE should auto-continue playback.
    func handoffActive(nowMs: Int) -> Bool {
        guard let h = handoff, h.by != SyncDevice.id else { return false }
        return nowMs - h.atMs < Self.handoffWindowMs
    }

    init?(snap: DocumentSnapshot) {
        guard let d = snap.data(),
              let epoch = d["epoch"] as? Int,
              let ownerDev = d["ownerDeviceID"] as? String,
              let lease = d["leaseMs"] as? Int,
              let playback = PlaybackState(dict: d["playback"] as? [String: Any]),
              let qv = d["queueVersion"] as? Int else { return nil }
        self.epoch = epoch; self.ownerDeviceID = ownerDev
        self.leaseMs = lease; self.playback = playback
        self.queue = (d["queue"] as? [[String: Any]])?.compactMap(TrackRef.init(dict:)) ?? []
        self.queueVersion = qv
        self.updatedBy = d["updatedBy"] as? String ?? ""
        if let h = d["handoff"] as? [String: Any],
           let by = h["by"] as? String, let at = h["atMs"] as? Int {
            self.handoff = Handoff(by: by, atMs: at)
        }
    }

    /// The lazily-created singleton: idle, unowned. First play() takes over.
    static func idleDict() -> [String: Any] {
        [
            "epoch": 1,
            "ownerDeviceID": "",
            "leaseMs": 0,
            "playback": PlaybackState.empty.dict,
            "queue": [[String: Any]](),
            "queueVersion": 1,
            "updatedBy": SyncDevice.id,
        ]
    }
}

// MARK: - Queue intents (rebased by trackID anchors, never by index)

enum QueueOp {
    case insert(TrackRef, afterID: UUID?)   // nil = front
    case remove(UUID)
    case move(UUID, afterID: UUID?)
    case consumeHead(expected: UUID)        // CAS: owner's next() must not eat a concurrent insert
    case replaceAll([TrackRef])             // LWW for bulk local edits
}

// MARK: - Firestore transaction sugar (async/throwing)

extension Firestore {
    func txn<T>(_ body: @escaping (Transaction) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            runTransaction({ txn, errPtr -> Any? in
                do { return try body(txn) }
                catch {
                    errPtr?.pointee = error as NSError
                    return nil
                }
            }) { result, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: result as! T) }
            }
        }
    }
}
