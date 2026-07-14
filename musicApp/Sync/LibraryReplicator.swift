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
    private var localDownloads: [Download] = []

    // Down-sync: cloud → local via yt-dlp, one file in flight.
    private var listener: ListenerRegistration?
    private var meta: [String: TrackMeta] = [:]        // docId → cloud metadata
    private var downQueue: [TrackMeta] = []
    private var downloadingYT: Set<String> = []        // in-flight yt ids (≤1 at a time)
    private var downFails: [String: Int] = [:]         // yt id → attempts
    private var processedFailures: Set<UUID> = []
    private let findDuplicate: (String) -> Download?
    private let startDownload: (String, String, DownloadSource, String) -> Void
    private let applyMeta: (String, TrackMeta) -> Void
    private let applyDeletion: (String) -> Void

    /// Fast path only; the authoritative dedupe is the doc-exists check server-side.
    private var uploadedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "sync.uploaded.ids") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "sync.uploaded.ids") }
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
        // must not wait on the upload pump's 2s debounce.
        downloads
            .sink { [weak self] list in self?.localDownloads = list }
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
        downQueue.removeAll()
        downloadingYT.removeAll()
        downFails.removeAll()
        processedFailures.removeAll()
        listener?.remove()
        listener = db.collection("users").document(uid).collection("library")
            .addSnapshotListener { [weak self] snap, _ in
                guard let snap else { return }
                Task { @MainActor in self?.handleSnapshot(snap) }
            }
        // Re-diff on activation so a backlog uploads without waiting for a change.
        pumpUploads()
    }

    // MARK: - Down: cloud → local

    @MainActor
    private func handleSnapshot(_ snap: QuerySnapshot) {
        for change in snap.documentChanges {
            let id = change.document.documentID
            if change.type == .removed { meta.removeValue(forKey: id); continue }
            guard let m = TrackMeta(dict: change.document.data()) else { continue }
            meta[id] = m
            guard let yt = m.yt else { continue }

            if m.deleted {
                // Tombstone: never fetch it, and apply the deletion locally
                // unless we authored it (echo).
                downQueue.removeAll { $0.yt == yt }
                if m.metaBy != SyncDevice.id { applyDeletion(yt) }
                continue
            }

            if hasLocally(m) {
                // Metadata (rename/crop/folder) for a track we have — apply
                // unless we authored the change. Idempotent: applyRemoteMeta
                // no-ops when values already match.
                if m.metaBy != SyncDevice.id { applyMeta(yt, m) }
            } else if !downloadingYT.contains(yt),
                      !downQueue.contains(where: { $0.yt == yt }) {
                downQueue.append(m)
            }
        }
        pumpDownloads()
    }

    private func hasLocally(_ m: TrackMeta) -> Bool {
        guard let yt = m.yt else { return true }  // nothing fetchable — treat as handled
        if findDuplicate(yt) != nil { return true }
        let name = Self.normalize(m.name)
        return localDownloads.contains { Self.normalize($0.name) == name }
    }

    private func pumpDownloads() {
        guard downloadingYT.isEmpty, !downQueue.isEmpty else { return }
        let m = downQueue.removeFirst()
        guard let yt = m.yt else { pumpDownloads(); return }
        if meta.values.first(where: { $0.yt == yt })?.deleted == true { pumpDownloads(); return }
        if hasLocally(m) { pumpDownloads(); return }  // raced with a manual/other-source add
        downloadingYT.insert(yt)
        startDownload("https://www.youtube.com/watch?v=\(yt)", yt, .youtube, m.name)
    }

    private func handleFailures(_ list: [FailedDownload]) {
        for failed in list where !processedFailures.contains(failed.id) {
            processedFailures.insert(failed.id)
            guard let yt = downloadingYT.first(where: { failed.url.contains($0) }) else { continue }
            downloadingYT.remove(yt)
            let attempts = (downFails[yt] ?? 0) + 1
            downFails[yt] = attempts
            // Up to 3 attempts, then drop until the next snapshot (mirrors replicator.ts).
            if attempts < 3, let m = meta.values.first(where: { $0.yt == yt }) {
                downQueue.append(m)
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
        guard !uploadInFlight, let next = pendingUploads.first else { return }
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
        // place (matched by yt) instead of minting a duplicate.
        let name = Self.normalize(d.name)
        if let (docId, m) = meta.first(where: {
            ($0.value.yt != nil && $0.value.yt == d.videoID) ||
            Self.normalize($0.value.name) == name
        }).map({ ($0.key, $0.value) }) {
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
        guard !uid.isEmpty,
              let docId = meta.first(where: { $0.value.yt == yt })?.key else { return nil }
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

    func pushTombstone(for d: Download) {
        guard let yt = d.videoID, let ref = docRef(forYT: yt) else { return }
        Task {
            try? await ref.setData([
                "deleted": true,
                "metaAt": FieldValue.serverTimestamp(),
                "metaBy": SyncDevice.id,
            ], merge: true)
        }
    }

    /// Windows-illegal chars get replaced with "_" at replication time on
    /// desktop; compare names through the same lens so "What? Song" matches
    /// "What_ Song" (twin of desktop/src/player.ts's `norm`).
    private static func normalize(_ s: String) -> String {
        let illegal = Set("<>:\"/\\|?*")
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s { out.append(illegal.contains(ch) ? "_" : ch) }
        return out.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
