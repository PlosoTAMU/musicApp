import Foundation
import Combine
import FirebaseFirestore

/// Two-way playlist replication — users/{uid}/playlists/{playlistId}.
///
/// Doc shape (desktop/src/playlists.ts is the twin — FIELD NAMES ARE THE
/// CONTRACT):
///   { name, tracks: [{id, name, yt?}], updatedAtMs, by, deleted? }
///
/// Tracks carry name+yt, not just ids: desktop files have PATH-DERIVED ids
/// (sha1 of the absolute path), so a desktop-authored entry's `id` matches no
/// iOS `Download.id` — ever. Entries must therefore be resolved through the
/// same id → yt → name chain the queue uses (`TrackResolving`), and the raw
/// cloud descriptor must be preserved for anything this device can't resolve.
///
/// Before sync-audit-4 B3 neither happened: `applyRemote` kept only the `id`
/// field, so a desktop playlist arrived as N phantom UUIDs and rendered empty
/// on iOS; and the first local edit re-uploaded those entries as
/// `{id, name: ""}` with `yt` dropped, after which DESKTOP could no longer
/// resolve them either — silent, permanent loss of a shared playlist.
///
/// Deletes are tombstones (deleted: true), not doc removals — an offline
/// device that still holds the playlist must not resurrect it on reconnect.
///
/// Echo suppression: `cloud` mirrors the last-seen cloud state; the local
/// observer only uploads a playlist whose content DIFFERS from that mirror,
/// so applying a snapshot never bounces back as an upload.
@MainActor
final class PlaylistSync {

    /// One entry of the cloud `tracks` array, kept verbatim so a device that
    /// can't resolve it locally still round-trips it untouched.
    private struct CloudTrack {
        let id: String          // author's local id — opaque to other devices
        let name: String
        let yt: String?

        var dict: [String: Any] {
            var d: [String: Any] = ["id": id, "name": name]
            if let yt { d["yt"] = yt }
            return d
        }

        init(id: String, name: String, yt: String?) {
            self.id = id; self.name = name; self.yt = yt
        }

        init?(dict: [String: Any]) {
            guard let id = dict["id"] as? String else { return nil }
            self.init(id: id, name: dict["name"] as? String ?? "",
                      yt: dict["yt"] as? String)
        }

        /// Playlist docs carry no `folder`, so the (name, folder) rung of the
        /// resolution chain is skipped — same as desktop's
        /// `resolve({ id, name, folder: "", yt }, lib)`.
        var ref: TrackRef {
            // A non-UUID (or foreign-UUID) id simply misses the byId index and
            // falls through to yt → name, which is the whole point.
            TrackRef(id: UUID(uuidString: id) ?? UUID(),
                     name: name, folder: "", ytID: yt)
        }
    }

    /// One row of the rebuilt cloud list: the descriptor to write, plus the
    /// local Download it came from (nil for a preserved ghost). A struct, not a
    /// tuple — Swift key paths can't address tuple elements.
    private struct MergedEntry {
        let track: CloudTrack
        let localID: UUID?
    }

    private struct CloudDoc {
        var name: String
        /// Verbatim cloud order — the source of truth for re-upload.
        var tracks: [CloudTrack]
        /// Parallel to `tracks`: the local Download this entry resolved to, or
        /// nil when this device doesn't have the file (a "ghost" entry).
        var resolved: [UUID?]
        var updatedAtMs: Int
        var deleted: Bool

        /// The locally-playable subset, in cloud order — what `Playlist`
        /// stores and every iOS view renders.
        var localTrackIDs: [UUID] { resolved.compactMap { $0 } }
    }

    private let db: Firestore
    private let manager: PlaylistManager
    private let download: (UUID) -> Download?
    private let resolver: TrackResolving
    private var uid = ""
    private var listener: ListenerRegistration?
    private var bag = Set<AnyCancellable>()
    private var cloud: [UUID: CloudDoc] = [:]

    init(db: Firestore, manager: PlaylistManager,
         resolver: TrackResolving,
         download: @escaping (UUID) -> Download?) {
        self.db = db
        self.manager = manager
        self.resolver = resolver
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
        // documentChanges, not the full documents list — this only re-derives
        // playlists that actually changed in this snapshot instead of every
        // playlist on every update (deletes are tombstones via a `deleted`
        // field, not real doc removal, so `.removed` here is a rare/
        // out-of-band case — just drop it from the cache, matching this
        // function's prior behavior of never explicitly untracking those).
        for change in snap.documentChanges {
            guard let id = UUID(uuidString: change.document.documentID) else { continue }
            if change.type == .removed { cloud.removeValue(forKey: id); continue }
            let d = change.document.data()
            let tracks = ((d["tracks"] as? [[String: Any]]) ?? [])
                .compactMap(CloudTrack.init(dict:))
            let incoming = CloudDoc(
                name: d["name"] as? String ?? "",
                tracks: tracks,
                resolved: tracks.map { resolver.resolve($0.ref)?.id },
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
                    || manager.playlists[idx].trackIDs != incoming.localTrackIDs {
                    manager.playlists[idx].name = incoming.name
                    manager.playlists[idx].trackIDs = incoming.localTrackIDs
                    changed = true
                }
            } else {
                manager.playlists.append(
                    Playlist(id: id, name: incoming.name,
                             trackIDs: incoming.localTrackIDs))
                changed = true
            }
        }
        if changed { manager.savePlaylists() }
    }

    /// Re-run resolution against the current library. A track that finished
    /// downloading after the last snapshot was a ghost until now; without this
    /// it stays invisible in the playlist until the cloud doc happens to
    /// change again. Both the cloud mirror and the local list are updated in
    /// the same pass, so `pushDiff` sees no delta and nothing re-uploads.
    func refreshResolution() {
        guard !uid.isEmpty else { return }
        var changed = false
        for id in cloud.keys {
            guard let doc = cloud[id], !doc.deleted else { continue }
            let resolved = doc.tracks.map { resolver.resolve($0.ref)?.id }
            guard resolved != doc.resolved else { continue }
            cloud[id]?.resolved = resolved
            let localIDs = resolved.compactMap { $0 }
            if let idx = manager.playlists.firstIndex(where: { $0.id == id }),
               manager.playlists[idx].trackIDs != localIDs {
                manager.playlists[idx].trackIDs = localIDs
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
            if c == nil || c!.deleted || c!.name != p.name
                || c!.localTrackIDs != p.trackIDs {
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
        let merged = mergedTracks(for: p)
        // Pre-record so the echo snapshot compares equal and doesn't re-upload.
        cloud[p.id] = CloudDoc(name: p.name,
                               tracks: merged.map(\.track),
                               resolved: merged.map(\.localID),
                               updatedAtMs: at, deleted: false)
        let payload = merged.map { $0.track.dict }
        let ref = collectionRef().document(p.id.uuidString)
        Task {
            try? await ref.setData(["name": p.name, "tracks": payload,
                                    "updatedAtMs": at, "by": SyncDevice.id])
        }
    }

    /// Rebuild the cloud `tracks` array from the local (resolvable) list while
    /// preserving every entry this device could not resolve, at its position.
    ///
    /// Twin of PlaybackSyncEngine.mergeGhosts. Executable spec + cases:
    /// `desktop/tests/syncAudit-ghostmerge.test.ts` — keep the three in step.
    ///
    /// Each ghost re-enters after the nearest preceding cloud entry that still
    /// survives locally, so a local edit reorders/adds/removes what it can see
    /// without silently deleting — or blanking — tracks it merely doesn't have.
    ///
    /// `placed` is load-bearing: a RUN of consecutive ghosts sharing one anchor
    /// must keep cloud order. Inserting each at `anchor + 1` pushes the
    /// previous one right and reverses the run (sync-audit-4 B7), so each
    /// sibling is offset past the ones already placed for that same anchor.
    /// `base` is recomputed every iteration because inserts for earlier anchors
    /// shift the anchor's index.
    private func mergedTracks(for p: Playlist) -> [MergedEntry] {
        let prior = cloud[p.id]

        // Descriptor for a track we DO have locally. Falls back to the prior
        // cloud descriptor if the Download vanished mid-edit, so a name is
        // never blanked out.
        func descriptor(for tid: UUID) -> CloudTrack {
            if let d = download(tid) {
                return CloudTrack(id: tid.uuidString, name: d.name, yt: d.videoID)
            }
            if let prior, let i = prior.resolved.firstIndex(of: tid) {
                return prior.tracks[i]
            }
            return CloudTrack(id: tid.uuidString, name: "", yt: nil)
        }

        var out: [MergedEntry] =
            p.trackIDs.map { MergedEntry(track: descriptor(for: $0), localID: $0) }

        guard let prior else { return out }

        let frontKey = ""   // sentinel: ghosts with no surviving predecessor
        var placed: [String: Int] = [:]

        for (i, resolvedID) in prior.resolved.enumerated() where resolvedID == nil {
            let ghost = prior.tracks[i]
            let anchor: UUID? = prior.resolved[..<i]
                .compactMap { $0 }
                .last { id in out.contains { $0.localID == id } }
            let key = anchor?.uuidString ?? frontKey
            let offset = placed[key] ?? 0
            let base = anchor.flatMap { a in
                out.firstIndex { $0.localID == a }.map { $0 + 1 }
            } ?? 0
            out.insert(MergedEntry(track: ghost, localID: nil), at: base + offset)
            placed[key] = offset + 1
        }
        return out
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
