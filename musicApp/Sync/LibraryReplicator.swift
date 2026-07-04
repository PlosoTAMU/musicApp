import Foundation
import Combine
import FirebaseFirestore

/// Mobile → cloud replication — LINK-SYNC model (free plan, no Storage).
/// Watches DownloadManager's list; any completed download not yet mirrored
/// gets a metadata doc under users/{uid}/library with its YouTube id. The
/// doc IS the track: other devices download their own audio via yt-dlp from
/// the yt id. No binary ever leaves the device.
final class LibraryReplicator {

    private let db: Firestore
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
}
