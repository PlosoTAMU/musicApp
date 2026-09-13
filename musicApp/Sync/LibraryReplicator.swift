import Foundation
import Combine
import FirebaseFirestore

/// Mobile ↔ cloud replication — LINK-SYNC model (free plan, no Storage).
/// Up: any completed download not yet mirrored gets a metadata doc under
/// users/{uid}/library with its YouTube id. Down: any cloud doc with a `yt`
/// id not present locally gets pulled via yt-dlp through DownloadManager's
/// existing headless background-download pipeline. The doc IS the track:
/// each device downloads its own audio via yt-dlp from the yt id. No binary
/// ever leaves the device.
final class LibraryReplicator {

    private let db: Firestore
    private var bag = Set<AnyCancellable>()
    private var uid = ""

    // Serial upload pump — one file in flight, cellular-friendly.
    private var pendingUploads: [Download] = []
    private var uploadInFlight = false

    // Down-sync: cloud → local via yt-dlp, one file in flight.
    private var listener: ListenerRegistration?
    private var meta: [String: TrackMeta] = [:]        // docId → cloud metadata
    private var metaByYt: [String: String] = [:]       // yt → CANONICAL docId (see
                                                       // canonicalDocId) — kills the
                                                       // O(N) `meta.values.first`
                                                       // that ran per snapshot doc
                                                       // change and per pump step.
    private var docsByYt: [String: Set<String>] = [:]  // yt → every docId carrying it
    private var metaByNormName: [String: String] = [:] // name key → docId
                                                       // for upload-side dedupe.
    /// The library listener has delivered its first snapshot. Until then
    /// `meta` is empty and the upload pump must NOT run: `upload()` looks for
    /// a doc to match by yt/name, finds nothing, and mints a fresh doc under
    /// this record's UUID — a DUPLICATE of the doc the desktop already holds
    /// for the same song, every time the phone connected with anything
    /// unmirrored (sync-audit-6). Twin of replicator.ts `ready`.
    private var snapshotReady = false
    private var downQueue: [TrackMeta] = []
    // Membership index over downQueue. The initial listener snapshot delivers
    // every cloud doc as one batch, and the "already queued?" check ran a
    // linear scan of a queue that grows with the batch — O(n²) on MainActor,
    // the same launch-freeze shape F9 fixed elsewhere (sync-audit-4 M8).
    private var downQueuedYT: Set<String> = []
    private var downloadingYT: Set<String> = []        // in-flight yt ids (≤1 at a time)
    private var downFails: [String: Int] = [:]         // yt id → attempts
    private var processedFailures: Set<UUID> = []
    private var localNames: Set<String> = []            // normalized names, for hasLocally()
    private let findDuplicate: (String) -> Download?
    private let startDownload: (String, String, DownloadSource, String) -> Void
    private let applyMeta: (String, TrackMeta) -> Void
    private let applyDeletion: (String) -> Void

    /// Fast path only; the authoritative dedupe is the doc-exists check
    /// server-side.
    ///
    /// Scoped PER UID. It used to live under one global key, so after switching
    /// to a different home every local track was still marked "uploaded" and
    /// `enqueueMissing` filtered them all out — the new account received no
    /// library docs at all, ever (sync-audit-4 M9). Desktop never had this: its
    /// dedupe map is per-uid in memory and cleared by replicator.stop().
    private static let legacyUploadedKey = "sync.uploaded.ids"
    private var uploadedKey: String { "sync.uploaded.ids.\(uid)" }
    private var uploadedIDs: Set<String> {
        get {
            let d = UserDefaults.standard
            if let scoped = d.stringArray(forKey: uploadedKey) { return Set(scoped) }
            // One-time adoption of the pre-scoping key for the FIRST home this
            // install syncs with, so existing users don't re-mirror everything.
            if let legacy = d.stringArray(forKey: Self.legacyUploadedKey) {
                d.set(legacy, forKey: uploadedKey)
                d.removeObject(forKey: Self.legacyUploadedKey)
                return Set(legacy)
            }
            return []
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: uploadedKey) }
    }

    init(db: Firestore,
         downloads: AnyPublisher<[Download], Never>,
         failedDownloads: AnyPublisher<[FailedDownload], Never>,
         metaChanges: AnyPublisher<Download, Never>,
         deletions: AnyPublisher<Download, Never>,
         findDuplicate: @escaping (String) -> Download?,
         startDownload: @escaping (String, String, DownloadSource, String) -> Void,
         applyMeta: @escaping (String, TrackMeta) -> Void,
         applyDeletion: @escaping (String) -> Void) {
        self.db = db
        self.findDuplicate = findDuplicate
        self.startDownload = startDownload
        self.applyMeta = applyMeta
        self.applyDeletion = applyDeletion

        // Immediate cache for down-sync's "do we already have this" check —
        // must not wait on the upload pump's 2s debounce. Normalized names are
        // pre-hashed into a Set: the initial listener snapshot delivers every
        // cloud doc as one batch of "added" changes, and hasLocally() runs once
        // per doc — an O(n) linear scan there made the whole batch O(n²) on the
        // main actor, freezing the app on launch for any sizeable library.
        downloads
            .sink { [weak self] list in
                self?.localNames = Set(list.map { Self.normalize($0.name) })
            }
            .store(in: &bag)

        // Debounce: DownloadManager mutates its array repeatedly mid-download;
        // only settled states are worth diffing for the upload pump.
        downloads
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] list in self?.enqueueMissing(list) }
            .store(in: &bag)

        failedDownloads
            .sink { [weak self] list in self?.handleFailures(list) }
            .store(in: &bag)

        metaChanges
            .sink { [weak self] d in self?.pushMeta(for: d) }
            .store(in: &bag)
        deletions
            .sink { [weak self] d in self?.pushTombstone(for: d) }
            .store(in: &bag)
    }

    func activate(uid: String) {
        self.uid = uid
        // Clear down-sync state to prevent stale metadata from interfering across account switches.
        meta.removeAll()
        metaByYt.removeAll()
        docsByYt.removeAll()
        metaByNormName.removeAll()
        downQueue.removeAll()
        downQueuedYT.removeAll()
        downloadingYT.removeAll()
        downFails.removeAll()
        processedFailures.removeAll()
        snapshotReady = false
        listener?.remove()
        listener = db.collection("users").document(uid).collection("library")
            .addSnapshotListener { [weak self] snap, _ in
                guard let snap else { return }
                Task { @MainActor in self?.handleSnapshot(snap) }
            }
        // The backlog upload runs once the first snapshot has landed
        // (handleSnapshot → pumpUploads); before that every match would miss.
    }

    /// Detach from the current home. Without this, `forgetHome` left the
    /// library listener running against the OLD uid, so a device that had
    /// "forgotten" a home kept mirroring into it (sync-audit-4 M9).
    func deactivate() {
        listener?.remove(); listener = nil
        uid = ""
        meta.removeAll()
        metaByYt.removeAll()
        docsByYt.removeAll()
        metaByNormName.removeAll()
        snapshotReady = false
        downQueue.removeAll()
        downQueuedYT.removeAll()
        downloadingYT.removeAll()
        downFails.removeAll()
        processedFailures.removeAll()
        pendingUploads.removeAll()
    }

    // MARK: - Down: cloud → local

    /// The doc that speaks for a yt when several live docs carry it (a
    /// duplicate minted by a pre-fix upload race on either end): the most
    /// recently edited one, ties broken by the smaller docId so both ends
    /// agree. nil ⇒ no LIVE doc — only tombstones — for that yt. Twin of
    /// desktop libraryMeta.ts `canonicalByYt`, which also cleans duplicates up.
    private func canonicalDocId(forYT yt: String) -> String? {
        var best: (id: String, at: Int)?
        for id in docsByYt[yt] ?? [] {
            guard let m = meta[id], !m.deleted else { continue }
            if let b = best {
                let wins = m.metaAtMs > b.at || (m.metaAtMs == b.at && id < b.id)
                if !wins { continue }
            }
            best = (id, m.metaAtMs)
        }
        return best?.id
    }

    private func reindex(yt: String) {
        if let canonical = canonicalDocId(forYT: yt) { metaByYt[yt] = canonical }
        else { metaByYt.removeValue(forKey: yt) }
    }

    @MainActor
    private func handleSnapshot(_ snap: QuerySnapshot) {
        var touchedYts = Set<String>()
        for change in snap.documentChanges {
            let id = change.document.documentID
            if change.type == .removed {
                if let old = meta.removeValue(forKey: id) {
                    if let yt = old.yt {
                        docsByYt[yt]?.remove(id)
                        if docsByYt[yt]?.isEmpty == true { docsByYt.removeValue(forKey: yt) }
                        reindex(yt: yt)
                    }
                    let n = Self.normalize(old.name)
                    if metaByNormName[n] == id { metaByNormName.removeValue(forKey: n) }
                }
                continue
            }
            guard let m = TrackMeta(dict: change.document.data()) else { continue }
            // Keep secondary indexes in step with the primary map: a rename
            // or yt-change (rare) leaves a stale pointer otherwise.
            if let prev = meta[id] {
                if let prevYt = prev.yt, prevYt != m.yt {
                    docsByYt[prevYt]?.remove(id)
                    if docsByYt[prevYt]?.isEmpty == true { docsByYt.removeValue(forKey: prevYt) }
                    reindex(yt: prevYt)
                }
                let prevName = Self.normalize(prev.name)
                if prevName != Self.normalize(m.name),
                   metaByNormName[prevName] == id { metaByNormName.removeValue(forKey: prevName) }
            }
            meta[id] = m
            let nameKey = Self.normalize(m.name)
            if !nameKey.isEmpty { metaByNormName[nameKey] = id }
            guard let yt = m.yt else { continue }
            docsByYt[yt, default: []].insert(id)
            reindex(yt: yt)
            touchedYts.insert(yt)
        }

        // Act per yt, not per doc, so a tombstone on a duplicate can't delete
        // a song whose canonical doc is alive, and a stale duplicate's name
        // can't rename a track back and forth against the canonical one.
        for yt in touchedYts {
            guard let canonicalId = metaByYt[yt], let m = meta[canonicalId] else {
                // Only tombstones remain for this yt: never fetch it, and
                // apply the deletion locally unless we authored it (echo).
                downQueue.removeAll { $0.yt == yt }
                downQueuedYT.remove(yt)
                let authoredHere = (docsByYt[yt] ?? []).contains { meta[$0]?.metaBy == SyncDevice.id }
                if !authoredHere { applyDeletion(yt) }
                continue
            }

            if hasLocally(m) {
                // Metadata (rename/crop/folder) for a track we have — apply
                // unless we authored the change. Idempotent: applyRemoteMeta
                // no-ops when values already match.
                if m.metaBy != SyncDevice.id { applyMeta(yt, m) }
            } else if !downloadingYT.contains(yt), !downQueuedYT.contains(yt) {
                downQueue.append(m)
                downQueuedYT.insert(yt)
            }
        }
        let firstSnapshot = !snapshotReady
        snapshotReady = true
        pumpDownloads()
        // The initial snapshot is in: the upload backlog can now dedupe
        // against real cloud state instead of an empty map.
        if firstSnapshot { pumpUploads() }
    }

    private func hasLocally(_ m: TrackMeta) -> Bool {
        guard let yt = m.yt else { return true }  // nothing fetchable — treat as handled
        if findDuplicate(yt) != nil { return true }
        let key = Self.normalize(m.name)
        return !key.isEmpty && localNames.contains(key)
    }

    private func metaForYt(_ yt: String) -> TrackMeta? {
        metaByYt[yt].flatMap { meta[$0] }
    }

    private func pumpDownloads() {
        // Was recursive with an O(N) `meta.values.first` per iteration — on a
        // first-sync backlog against a populated library that's ~N² work on
        // MainActor (sync-audit-3.md F9). While-loop + yt-index makes it O(N).
        while downloadingYT.isEmpty, !downQueue.isEmpty {
            let m = downQueue.removeFirst()
            guard let yt = m.yt else { continue }
            downQueuedYT.remove(yt)
            // No LIVE doc any more (tombstoned since it was queued) ⇒ skip.
            guard metaForYt(yt) != nil else { continue }
            if hasLocally(m) { continue }              // raced with a manual/other-source add
            downloadingYT.insert(yt)
            startDownload("https://www.youtube.com/watch?v=\(yt)", yt, .youtube, m.name)
            return                                     // one file in flight
        }
    }

    private func handleFailures(_ list: [FailedDownload]) {
        for failed in list where !processedFailures.contains(failed.id) {
            processedFailures.insert(failed.id)
            guard let yt = downloadingYT.first(where: { failed.url.contains($0) }) else { continue }
            downloadingYT.remove(yt)
            let attempts = (downFails[yt] ?? 0) + 1
            downFails[yt] = attempts
            // Up to 3 attempts, then drop until the next snapshot (mirrors replicator.ts).
            if attempts < 3, let m = metaForYt(yt) {
                downQueue.append(m)
                downQueuedYT.insert(yt)
            }
        }
        pumpDownloads()
    }

    // MARK: - Up: local → cloud

    private func enqueueMissing(_ list: [Download]) {
        guard !uid.isEmpty else { return }
        let done = uploadedIDs
        pendingUploads = list.filter { !done.contains($0.id.uuidString) && !$0.pendingDeletion }
        // A yt id that just finished downloading is no longer "in flight".
        for d in list {
            if let yt = d.videoID { downloadingYT.remove(yt); downFails.removeValue(forKey: yt) }
        }
        pumpUploads()
    }

    private func pumpUploads() {
        guard snapshotReady, !uploadInFlight, let next = pendingUploads.first else { return }
        pendingUploads.removeFirst()
        uploadInFlight = true
        Task { [weak self] in
            await self?.upload(next)
            await MainActor.run {
                self?.uploadInFlight = false
                self?.pumpUploads()
                self?.pumpDownloads()  // a finished download may have freed the down-queue
            }
        }
    }

    private func upload(_ d: Download) async {
        guard !uid.isEmpty else { return }
        let id = d.id.uuidString

        // Already mirrored under a DIFFERENT doc id — e.g. this file just
        // arrived via down-sync (which mints a fresh local UUID). If the match
        // is a tombstone, this is a manual re-download: revive the doc in
        // place (matched by yt) instead of minting a duplicate. Was an O(N)
        // dictionary scan per upload; now O(1) via the two secondary indexes.
        let name = Self.normalize(d.name)
        let matchDocId: String? = {
            if let yt = d.videoID, let idByYt = metaByYt[yt] { return idByYt }
            return metaByNormName[name]
        }()
        if let docId = matchDocId, let m = meta[docId] {
            if m.deleted {
                let ref = db.collection("users").document(uid)
                    .collection("library").document(docId)
                try? await ref.setData(metaFields(for: d), merge: true)
            }
            markUploaded(id)
            return
        }

        let docRef = db.collection("users").document(uid)
            .collection("library").document(id)
        do {
            // Another device may have mirrored this track already.
            if try await docRef.getDocument().exists {
                markUploaded(id)
                return
            }

            // Metadata only — the yt id is the source of truth; receiving
            // devices run their own yt-dlp download from it.
            let ext = d.url.pathExtension.isEmpty ? "m4a" : d.url.pathExtension.lowercased()
            var doc: [String: Any] = [
                "name": d.name, "folder": "", "ext": ext,
                "by": SyncDevice.id, "at": FieldValue.serverTimestamp(),
                "deleted": false,
                "metaAt": FieldValue.serverTimestamp(), "metaBy": SyncDevice.id,
            ]
            if let yt = d.videoID { doc["yt"] = yt }
            if let s = d.cropStartTime { doc["cropStartMs"] = Int(s * 1000) }
            if let e = d.cropEndTime { doc["cropEndMs"] = Int(e * 1000) }
            try await docRef.setData(doc)

            markUploaded(id)
            print("☁️ [Replicator] Mirrored \(d.name)")
        } catch {
            // Left unmarked — retried on the next downloads change or app launch.
            print("❌ [Replicator] Mirror failed for \(d.name): \(error)")
        }
    }

    private func markUploaded(_ id: String) {
        var s = uploadedIDs
        s.insert(id)
        uploadedIDs = s
    }

    // MARK: - Metadata push (local intent → cloud doc)

    private func docRef(forYT yt: String) -> DocumentReference? {
        guard !uid.isEmpty, let docId = metaByYt[yt] else { return nil }
        return db.collection("users").document(uid).collection("library").document(docId)
    }

    /// Fields iOS owns: name + crop. NEVER folder — desktop is folder authority.
    private func metaFields(for d: Download) -> [String: Any] {
        var f: [String: Any] = [
            "name": d.name,
            "deleted": false,
            "metaAt": FieldValue.serverTimestamp(),
            "metaBy": SyncDevice.id,
        ]
        f["cropStartMs"] = d.cropStartTime.map { Int($0 * 1000) } ?? FieldValue.delete()
        f["cropEndMs"] = d.cropEndTime.map { Int($0 * 1000) } ?? FieldValue.delete()
        return f
    }

    func pushMeta(for d: Download) {
        guard let yt = d.videoID, let ref = docRef(forYT: yt) else { return }
        Task { try? await ref.setData(self.metaFields(for: d), merge: true) }
    }

    /// Every live doc for the yt, not just the canonical one: a surviving
    /// duplicate would keep the song alive on the other device (its tombstone
    /// guard ignores a tombstone while any live doc remains).
    func pushTombstone(for d: Download) {
        guard !uid.isEmpty, let yt = d.videoID else { return }
        let ids = (docsByYt[yt] ?? []).filter { meta[$0]?.deleted == false }
        guard !ids.isEmpty else { return }
        let col = db.collection("users").document(uid).collection("library")
        Task {
            for id in ids {
                try? await col.document(id).setData([
                    "deleted": true,
                    "metaAt": FieldValue.serverTimestamp(),
                    "metaBy": SyncDevice.id,
                ], merge: true)
            }
        }
    }

    /// The shared cross-device name key (letters + digits only) — see
    /// SyncNames.key for why the old illegal-char lens was not enough.
    private static func normalize(_ s: String) -> String { SyncNames.key(s) }
}
