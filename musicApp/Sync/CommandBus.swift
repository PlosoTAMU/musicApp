import Foundation
import FirebaseFirestore

/// Follower → owner control channel.
///
/// Followers never mutate `playback` directly — the owner is the single writer
/// (fencing depends on it). Instead a follower appends a command doc; the owner
/// applies it to the local player, which round-trips as a normal fenced publish.
/// This keeps exactly one state-authority even when any device can press pause.
enum SyncCommand {
    case play, pause, next, previous
    case seek(ms: Int)
    /// Remote-mode "tap a song": ask the OWNER to play this track over there.
    /// The whole point of remote mode — a tap on the controlling device must
    /// never start audio locally.
    case playTrack(TrackRef)
    /// Resync ping: a device that just joined asks the current owner to
    /// re-publish its authoritative playback (fresh anchor). Not a transport
    /// mutation — the owner answers with a publish, nothing plays.
    case requestStatus

    var dict: [String: Any] {
        var d: [String: Any] = ["by": SyncDevice.id, "at": FieldValue.serverTimestamp()]
        switch self {
        case .play: d["t"] = "play"
        case .pause: d["t"] = "pause"
        case .next: d["t"] = "next"
        case .previous: d["t"] = "prev"
        case .seek(let ms): d["t"] = "seek"; d["ms"] = ms
        case .playTrack(let ref): d["t"] = "playTrack"; d["ref"] = ref.dict
        case .requestStatus: d["t"] = "status"
        }
        return d
    }

    init?(dict: [String: Any]) {
        switch dict["t"] as? String {
        case "play": self = .play
        case "pause": self = .pause
        case "next": self = .next
        case "prev": self = .previous
        case "seek": guard let ms = dict["ms"] as? Int else { return nil }; self = .seek(ms: ms)
        case "playTrack":
            guard let raw = dict["ref"] as? [String: Any],
                  let ref = TrackRef(dict: raw) else { return nil }
            self = .playTrack(ref)
        case "status": self = .requestStatus
        default: return nil
        }
    }
}

final class CommandBus {

    private let db: Firestore
    private let sessionRef: () -> DocumentReference?
    private var listener: ListenerRegistration?

    /// Commands older than this on arrival are drained without applying —
    /// protects against a backlog replaying (owner was offline, follower mashed pause).
    private static let staleMs: Double = 30_000

    init(db: Firestore, sessionRef: @escaping () -> DocumentReference?) {
        self.db = db
        self.sessionRef = sessionRef
    }

    func send(_ cmd: SyncCommand) {
        sessionRef()?.collection("commands").addDocument(data: cmd.dict)
    }

    /// Owner-side. Applies fresh commands in server order, deletes every doc
    /// (applied or stale) so the collection never grows.
    func startListening(handler: @escaping (SyncCommand) -> Void) {
        stopListening()
        guard let ref = sessionRef() else { return }
        // The initial batch is drained WITHOUT applying: those commands were
        // aimed at the previous owner ("pause the old song"), and executing
        // them against a fresh reign pauses/seeks playback the sender never
        // meant to touch. The new owner publishes its state anyway.
        var isInitialBatch = true
        listener = ref.collection("commands").order(by: "at")
            .addSnapshotListener { snap, _ in
                guard let snap else { return }
                defer { isInitialBatch = false }
                if isInitialBatch {
                    for change in snap.documentChanges where change.type == .added {
                        change.document.reference.delete()
                    }
                    return
                }
                for change in snap.documentChanges where change.type == .added {
                    let doc = change.document
                    // serverTimestamp is nil until acked; treat pending as fresh.
                    let ageMs: Double
                    if let ts = doc.get("at") as? Timestamp {
                        let serverMs = Double(ts.seconds) * 1000 + Double(ts.nanoseconds) / 1_000_000
                        ageMs = Double(ServerClock.shared.nowMs) - serverMs
                    } else {
                        ageMs = 0
                    }
                    if ageMs < Self.staleMs,
                       doc.get("by") as? String != SyncDevice.id,
                       let cmd = SyncCommand(dict: doc.data()) {
                        handler(cmd)
                    }
                    doc.reference.delete()
                }
            }
    }

    func stopListening() {
        listener?.remove(); listener = nil
    }
}
