import Foundation
import Combine
import FirebaseFirestore

/// Two-way playlist replication — users/{uid}/playlists/{playlistId}.
///
/// Doc shape (desktop/src/playlists.ts is the twin — FIELD NAMES ARE THE
/// CONTRACT):
///   { name, tracks: [{id, name, yt?}], updatedAtMs, by, deleted? }
///
/// Tracks carry name+yt, not just ids: desktop files have path-derived ids,
/// so it resolves playlist entries through the same id → yt → name chain the
/// queue uses. Deletes are tombstones (deleted: true), not doc removals — an
/// offline device that still holds the playlist must not resurrect it on
/// reconnect.
///
/// Echo suppression: `cloud` mirrors the last-seen cloud state; the local
/// observer only uploads a playlist whose content DIFFERS from that mirror,
/// so applying a snapshot never bounces back as an upload.
@MainActor
final class PlaylistSync {

    private struct CloudDoc {
        var name: String
        var trackIDs: [UUID]
        var updatedAtMs: Int
        var deleted: Bool
    }

    private let db: Firestore
    private let manager: PlaylistManager
    private let download: (UUID) -> Download?
    private var uid = ""
    private var listener: ListenerRegistration?
    private var bag = Set<AnyCancellable>()
    private var cloud: [UUID: CloudDoc] = [:]

    init(db: Firestore, manager: PlaylistManager,
         download: @escaping (UUID) -> Download?) {
        self.db = db
        self.manager = manager
        self.download = download
        manager.$playlists
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] local in self?.pushDiff(local) }
            .store(in: &bag)
    }

    func activate(uid: String) {
        self.uid = uid
        listener?.remove()
        listener = collectionRef().addSnapshotListener { [weak self] snap, _ in
            guard let snap else { return }
            Task { @MainActor in self?.applyRemote(snap) }
        }
    }

    func deactivate() {
        listener?.remove(); listener = nil
        cloud.removeAll()
        uid = ""
    }

    private func collectionRef() -> CollectionReference {
        db.collection("users").document(uid).collection("playlists")
    }

    // MARK: - Cloud → local

    private func applyRemote(_ snap: QuerySnapshot) {
        var changed = false
        for doc in snap.documents {
            guard let id = UUID(uuidString: doc.documentID) else { continue }
            let d = doc.data()
            let incoming = CloudDoc(
                name: d["name"] as? String ?? "",
                trackIDs: ((d["tracks"] as? [[String: Any]]) ?? [])
                    .compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) },
                updatedAtMs: (d["updatedAtMs"] as? NSNumber)?.intValue ?? 0,
                deleted: d["deleted"] as? Bool ?? false)
            cloud[id] = incoming

            if incoming.deleted {
                if let idx = manager.playlists.firstIndex(where: { $0.id == id }) {
                    manager.playlists.remove(at: idx)
                    changed = true
                }
            } else if let idx = manager.playlists.firstIndex(where: { $0.id == id }) {
                if manager.playlists[idx].name != incoming.name
                    || manager.playlists[idx].trackIDs != incoming.trackIDs {
                    manager.playlists[idx].name = incoming.name
                    manager.playlists[idx].trackIDs = incoming.trackIDs
                    changed = true
                }
            } else {
                manager.playlists.append(
                    Playlist(id: id, name: incoming.name, trackIDs: incoming.trackIDs))
                changed = true
            }
        }
        if changed { manager.savePlaylists() }
    }

    // MARK: - Local → cloud

    private func pushDiff(_ local: [Playlist]) {
        guard !uid.isEmpty else { return }

        for p in local {
            let c = cloud[p.id]
            if c == nil || c!.deleted || c!.name != p.name || c!.trackIDs != p.trackIDs {
                upload(p)
            }
        }
        // A cloud playlist that is live but locally absent was deleted HERE
        // (down-sync inserts before this observer ever sees a list without it).
        for (id, c) in cloud where !c.deleted && !local.contains(where: { $0.id == id }) {
            tombstone(id)
        }
    }

    private func upload(_ p: Playlist) {
        let at = ServerClock.shared.nowMs
        // Pre-record so the echo snapshot compares equal and doesn't re-upload.
        cloud[p.id] = CloudDoc(name: p.name, trackIDs: p.trackIDs,
                               updatedAtMs: at, deleted: false)
        let tracks: [[String: Any]] = p.trackIDs.map { tid in
            let d = download(tid)
            var t: [String: Any] = ["id": tid.uuidString, "name": d?.name ?? ""]
            if let yt = d?.videoID { t["yt"] = yt }
            return t
        }
        let ref = collectionRef().document(p.id.uuidString)
        Task {
            try? await ref.setData(["name": p.name, "tracks": tracks,
                                    "updatedAtMs": at, "by": SyncDevice.id])
        }
    }

    private func tombstone(_ id: UUID) {
        cloud[id]?.deleted = true
        let ref = collectionRef().document(id.uuidString)
        Task {
            try? await ref.setData(["deleted": true,
                                    "updatedAtMs": ServerClock.shared.nowMs,
                                    "by": SyncDevice.id], merge: true)
        }
    }
}
