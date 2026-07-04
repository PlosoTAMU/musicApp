import Foundation
import Combine
import FirebaseFirestore
import FirebaseStorage

/// Mobile → cloud replication. Watches DownloadManager's list; any completed
/// download not yet mirrored is uploaded to Storage with a metadata doc under
/// libraries/{lib}/tracks. Desktop clients stream down what they lack —
/// ghost queue entries heal themselves.
final class LibraryReplicator {

    private let db: Firestore
    private let storage = Storage.storage()
    private var bag = Set<AnyCancellable>()
    private var uid = ""

    // Serial upload pump — one file in flight, cellular-friendly.
    private var pending: [Download] = []
    private var inFlight = false

    /// Fast path only; the authoritative dedupe is the doc-exists check server-side.
    private var uploadedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "sync.uploaded.ids") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "sync.uploaded.ids") }
    }

    init(db: Firestore, downloads: AnyPublisher<[Download], Never>) {
        self.db = db
        // Debounce: DownloadManager mutates its array repeatedly mid-download;
        // only settled states are worth diffing.
        downloads
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] list in self?.enqueueMissing(list) }
            .store(in: &bag)
    }

    func activate(uid: String) {
        self.uid = uid
        // Re-diff on activation so a backlog uploads without waiting for a change.
        pump()
    }

    private func enqueueMissing(_ list: [Download]) {
        guard !uid.isEmpty else { return }
        let done = uploadedIDs
        pending = list.filter { !done.contains($0.id.uuidString) && !$0.pendingDeletion }
        pump()
    }

    private func pump() {
        guard !inFlight, let next = pending.first else { return }
        pending.removeFirst()
        inFlight = true
        Task { [weak self] in
            await self?.upload(next)
            await MainActor.run {
                self?.inFlight = false
                self?.pump()
            }
        }
    }

    private func upload(_ d: Download) async {
        guard !uid.isEmpty else { return }
        let id = d.id.uuidString
        let docRef = db.collection("users").document(uid)
            .collection("library").document(id)
        do {
            // Storage rules reject files ≥100 MB — without this guard the upload
            // fails forever and re-fires on every downloads change (battery +
            // cellular drain). Permanent skip, not retry fodder.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: d.url.path),
               let size = attrs[.size] as? Int64, size >= 100 * 1024 * 1024 {
                markUploaded(id)
                print("⏭️ [Replicator] \(d.name) exceeds 100 MB — skipped")
                return
            }

            // Another device may have mirrored this track already.
            if try await docRef.getDocument().exists {
                markUploaded(id)
                return
            }

            let ext = d.url.pathExtension.isEmpty ? "m4a" : d.url.pathExtension.lowercased()
            let path = "users/\(uid)/audio/\(id).\(ext)"
            let meta = StorageMetadata()
            meta.contentType = "audio/\(ext == "mp3" ? "mpeg" : ext)"
            _ = try await storage.reference(withPath: path)
                .putFileAsync(from: d.url, metadata: meta)

            // Metadata doc LAST — desktop listeners only ever see tracks whose
            // binary is already fully in Storage.
            var doc: [String: Any] = [
                "name": d.name, "folder": "", "ext": ext, "path": path,
                "by": SyncDevice.id, "at": FieldValue.serverTimestamp(),
            ]
            if let yt = d.videoID { doc["yt"] = yt }
            try await docRef.setData(doc)

            markUploaded(id)
            print("☁️ [Replicator] Uploaded \(d.name)")
        } catch {
            // Left unmarked — retried on the next downloads change or app launch.
            print("❌ [Replicator] Upload failed for \(d.name): \(error)")
        }
    }

    private func markUploaded(_ id: String) {
        var s = uploadedIDs
        s.insert(id)
        uploadedIDs = s
    }
}
