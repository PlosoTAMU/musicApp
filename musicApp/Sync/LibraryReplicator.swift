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

    /// Fast path only; the authoritative dedupe is the doc-exists check server-side.
    private var uploadedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "sync.uploaded.ids") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "sync.uploaded.ids") }
    }

    init(db: Firestore,
         downloads: AnyPublisher<[Download], Never>,
         failedDownloads: AnyPublisher<[FailedDownload], Never>,
         findDuplicate: @escaping (String) -> Download?,
         startDownload: @escaping (String, String, DownloadSource, String) -> Void) {
        self.db = db
        self.findDuplicate = findDuplicate
        self.startDownload = startDownload

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
            if let yt = m.yt, !hasLocally(m),
               !downloadingYT.contains(yt), !downQueue.contains(where: { $0.yt == yt }) {
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

    private func inCloud(_ d: Download) -> Bool {
        let name = Self.normalize(d.name)
        return meta.values.contains {
            ($0.yt != nil && $0.yt == d.videoID) || Self.normalize($0.name) == name
        }
    }

    private func upload(_ d: Download) async {
        guard !uid.isEmpty else { return }
        let id = d.id.uuidString

        // Already mirrored under a DIFFERENT doc id — e.g. this file just
        // arrived via down-sync (which mints a fresh local UUID). Mark done,
        // no duplicate doc.
        if inCloud(d) { markUploaded(id); return }

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
            ]
            if let yt = d.videoID { doc["yt"] = yt }
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
