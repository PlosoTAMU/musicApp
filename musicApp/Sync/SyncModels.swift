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

    init(id: UUID, name: String, folder: String, ytID: String?) {
        self.id = id; self.name = name; self.folder = folder; self.ytID = ytID
    }

    init(track: Track) {
        self.init(id: track.id, name: track.name, folder: track.folderName,
                  ytID: TrackRef.extractYTID(from: track.url))
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
    var rev: Int             // monotonic per-epoch; (epoch, rev) totally orders writes

    static let empty = PlaybackState(track: nil, isPlaying: false, positionMs: 0,
                                     anchorMs: 0, rateX1000: 1000, rev: 0)

    /// Follower-side extrapolation — the reason progress_ms never needs streaming.
    func positionMs(atServerMs now: Int) -> Int {
        guard isPlaying else { return positionMs }
        let elapsed = max(0, now - anchorMs)
        return positionMs + Int(Double(elapsed) * Double(rateX1000) / 1000.0)
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["playing": isPlaying, "pos": positionMs,
                                "anchor": anchorMs, "rate": rateX1000, "rev": rev]
        if let track { d["track"] = track.dict }
        return d
    }

    init(track: TrackRef?, isPlaying: Bool, positionMs: Int, anchorMs: Int,
         rateX1000: Int, rev: Int) {
        self.track = track; self.isPlaying = isPlaying; self.positionMs = positionMs
        self.anchorMs = anchorMs; self.rateX1000 = rateX1000; self.rev = rev
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
                  rateX1000: rate, rev: rev)
    }
}

// MARK: - Session document

struct SessionState {
    var epoch: Int
    var ownerDeviceID: String
    var ownerUID: String
    var leaseMs: Int          // last lease renewal (ServerClock ms)
    var members: [String]     // Firebase UIDs
    var playback: PlaybackState
    var queue: [TrackRef]
    var queueVersion: Int
    var updatedBy: String     // device id of last writer — anti-echo

    static let leaseTTLMs = 45_000

    var leaseExpired: Bool { ServerClock.shared.nowMs > leaseMs + Self.leaseTTLMs }

    init?(snap: DocumentSnapshot) {
        guard let d = snap.data(),
              let epoch = d["epoch"] as? Int,
              let ownerDev = d["ownerDeviceID"] as? String,
              let ownerUID = d["ownerUID"] as? String,
              let lease = d["leaseMs"] as? Int,
              let members = d["members"] as? [String],
              let playback = PlaybackState(dict: d["playback"] as? [String: Any]),
              let qv = d["queueVersion"] as? Int else { return nil }
        self.epoch = epoch; self.ownerDeviceID = ownerDev; self.ownerUID = ownerUID
        self.leaseMs = lease; self.members = members; self.playback = playback
        self.queue = (d["queue"] as? [[String: Any]])?.compactMap(TrackRef.init(dict:)) ?? []
        self.queueVersion = qv
        self.updatedBy = d["updatedBy"] as? String ?? ""
    }

    static func freshDict(ownerUID: String, playback: PlaybackState,
                          queue: [TrackRef]) -> [String: Any] {
        [
            "epoch": 1,
            "ownerDeviceID": SyncDevice.id,
            "ownerUID": ownerUID,
            "leaseMs": ServerClock.shared.nowMs,
            "members": [ownerUID],
            "playback": playback.dict,
            "queue": queue.map(\.dict),
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
