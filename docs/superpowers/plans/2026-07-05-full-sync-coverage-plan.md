# Full Sync Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two remaining sync gaps between the iOS app and desktop companion — one-directional library down-sync and unsynced effects settings — per `docs/superpowers/specs/2026-07-04-full-sync-coverage-design.md`.

**Architecture:** Extend the existing LINK-SYNC Firestore model with (A) a snapshot listener in `LibraryReplicator.swift` that mirrors `replicator.ts`'s down-sync behavior, driving iOS's existing headless `DownloadManager.startBackgroundDownload`, and (B) a new singleton doc `users/{uid}/sync/settings` synced by twin classes `SettingsSync.swift` / `settingsSync.ts`, following the same LWW-by-snapshot-ordering pattern already used for the session and playlist docs.

**Tech Stack:** Swift/Combine/FirebaseFirestore (iOS), TypeScript/Firebase JS SDK (Electron desktop).

## Global Constraints

- Field names across the iOS/desktop doc contracts are load-bearing — do not rename without updating both sides (existing file-header convention: "FIELD NAMES ARE THE CONTRACT").
- Firestore rules already allow all reads/writes under `users/{uid}/**` (`firestore.rules:8-9`) — no rules changes needed for the new `sync/settings` doc.
- LWW timestamp fields (`at`) use `ServerClock.shared.nowMs` / `serverClock.nowMs` (plain Int ms), **not** `FieldValue.serverTimestamp()` — matches the existing `updatedAtMs` convention in `PlaylistSync.swift`/`playlists.ts` and `SessionState`, not the older convention in `LibraryReplicator`'s upload doc (which is untouched, pre-existing, out of scope to change).
- **No Swift compiler is available on this Windows dev box (no Xcode).** Every Swift task's "verification" step is a self-review checklist against sibling files, not a build/run. End each Swift-touching task by telling the user to build on their Mac to confirm — do not claim iOS verification that didn't happen.
- Desktop TypeScript changes verify with `npx tsc --noEmit`, run from the `desktop/` directory (repo root has no `package.json`).
- New Swift files need no `.pbxproj` edits — this Xcode project uses Xcode-16 `fileSystemSynchronizedGroups`.
- Out of scope (per design doc): volume sync, iOS-only pitch shift / effects-bypass toggle, any "download this now" push priority signal.

---

## File Structure

| File | Change |
|---|---|
| `musicApp/Sync/SyncModels.swift` | Add `TrackMeta` struct (wire twin of `protocol.ts`'s `TrackMeta`) |
| `musicApp/Sync/LibraryReplicator.swift` | Add down-sync listener/queue/retry; fix upload-side dedupe |
| `musicApp/Sync/SyncSessionManager.swift` | `attachReplication` gains 3 params; add `settingsSync` + `attachSettings` |
| `musicApp/ContentView.swift` | Update `attachReplication` call site; add `attachSettings` call |
| `musicApp/Sync/SettingsSync.swift` | **New** — iOS effects-settings sync |
| `desktop/src/settingsSync.ts` | **New** — desktop effects-settings sync |
| `desktop/src/ui.ts` | Instantiate `SettingsSync`, wire into `connect()` and the fx sliders |

---

### Task 1: `TrackMeta` Swift model

**Files:**
- Modify: `musicApp/Sync/SyncModels.swift`

**Interfaces:**
- Produces: `struct TrackMeta { let name: String; let folder: String; let yt: String?; let ext: String; let by: String; init?(dict: [String: Any]) }` — consumed by Task 2.

- [ ] **Step 1: Add the struct**

Insert immediately after the `TrackRef` struct's closing brace (after line 75, before `protocol TrackResolving`) in `musicApp/Sync/SyncModels.swift`:

```swift
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
```

- [ ] **Step 2: Self-review**

Confirm field names exactly match `desktop/src/protocol.ts`'s `TrackMeta` interface (`name`, `folder`, `yt?`, `ext`, `by`, `path?` — `path` is legacy/unused per that file's own comment, correctly omitted here).

- [ ] **Step 3: Commit**

```bash
git add musicApp/Sync/SyncModels.swift
git commit -m "feat(sync): add TrackMeta model for library down-sync"
```

---

### Task 2: Library down-sync in `LibraryReplicator.swift`

**Files:**
- Modify: `musicApp/Sync/LibraryReplicator.swift`

**Interfaces:**
- Consumes: `TrackMeta` (Task 1), `Download`/`DownloadSource`/`FailedDownload` (existing, `musicApp/Download.swift`), `SyncDevice.id` (existing, `SyncModels.swift`).
- Produces: `LibraryReplicator.init(db:downloads:failedDownloads:findDuplicate:startDownload:)` — new signature consumed by Task 3.

- [ ] **Step 1: Replace the file contents**

Replace all of `musicApp/Sync/LibraryReplicator.swift` with:

```swift
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
            guard let data = change.document.data(),
                  let m = TrackMeta(dict: data) else { continue }
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
```

- [ ] **Step 2: Self-review checklist**

- `handleSnapshot`/`hasLocally`/`pumpDownloads`/`handleFailures`/`enqueueMissing`/`pumpUploads`/`inCloud`/`upload`/`markUploaded`/`normalize` — every name used matches its definition (no `clearLayers`/`clearFullLayers`-style drift).
- `downloadingYT` never holds more than one id at a time (`pumpDownloads` guards on `.isEmpty` before inserting) — confirms "one file in flight" per design doc.
- `inCloud` is called from `upload`, which fixes the exact bug the design doc calls out: a down-synced track re-uploading as a duplicate doc.
- Compare against `musicApp/Sync/PlaylistSync.swift` for the `Task { @MainActor in ... }` listener-callback idiom — matched.

- [ ] **Step 3: Commit**

```bash
git add musicApp/Sync/LibraryReplicator.swift
git commit -m "feat(sync): add iOS library down-sync + fix upload dedupe"
```

---

### Task 3: Wire down-sync dependencies through `SyncSessionManager` + `ContentView`

**Files:**
- Modify: `musicApp/Sync/SyncSessionManager.swift`
- Modify: `musicApp/ContentView.swift`

**Interfaces:**
- Consumes: `LibraryReplicator.init(db:downloads:failedDownloads:findDuplicate:startDownload:)` (Task 2), `DownloadManager.findDuplicateByVideoID(videoID:source:)` and `.startBackgroundDownload(url:videoID:source:title:)` (existing, `musicApp/DownloadManager.swift`).

- [ ] **Step 1: Update `attachReplication` in `SyncSessionManager.swift`**

Replace:

```swift
    /// Wire the upload pipeline to DownloadManager:
    ///   sync.attachReplication(downloads: downloadManager.$downloads.eraseToAnyPublisher())
    func attachReplication(downloads: AnyPublisher<[Download], Never>) {
        replicator = LibraryReplicator(db: coordinator.db, downloads: downloads)
        if !uid.isEmpty { replicator?.activate(uid: uid) }
    }
```

with:

```swift
    /// Wire the upload/download pipeline to DownloadManager:
    ///   sync.attachReplication(
    ///     downloads: downloadManager.$downloads.eraseToAnyPublisher(),
    ///     failedDownloads: downloadManager.$failedDownloads.eraseToAnyPublisher(),
    ///     findDuplicate: { yt in downloadManager.findDuplicateByVideoID(videoID: yt, source: .youtube) },
    ///     startDownload: { url, yt, source, title in
    ///       downloadManager.startBackgroundDownload(url: url, videoID: yt, source: source, title: title)
    ///     })
    func attachReplication(downloads: AnyPublisher<[Download], Never>,
                           failedDownloads: AnyPublisher<[FailedDownload], Never>,
                           findDuplicate: @escaping (String) -> Download?,
                           startDownload: @escaping (String, String, DownloadSource, String) -> Void) {
        replicator = LibraryReplicator(db: coordinator.db, downloads: downloads,
                                       failedDownloads: failedDownloads,
                                       findDuplicate: findDuplicate, startDownload: startDownload)
        if !uid.isEmpty { replicator?.activate(uid: uid) }
    }
```

- [ ] **Step 2: Update the call site in `ContentView.swift`**

Replace:

```swift
                syncManager.attachReplication(
                    downloads: downloadManager.$downloads.eraseToAnyPublisher())
```

with:

```swift
                syncManager.attachReplication(
                    downloads: downloadManager.$downloads.eraseToAnyPublisher(),
                    failedDownloads: downloadManager.$failedDownloads.eraseToAnyPublisher(),
                    findDuplicate: { [weak downloadManager] yt in
                        downloadManager?.findDuplicateByVideoID(videoID: yt, source: .youtube)
                    },
                    startDownload: { [weak downloadManager] url, yt, source, title in
                        downloadManager?.startBackgroundDownload(url: url, videoID: yt, source: source, title: title)
                    })
```

- [ ] **Step 3: Self-review**

Confirm this is the only call site of `attachReplication` in the repo (it was — `grep -rn attachReplication musicApp` before this task showed exactly one).

- [ ] **Step 4: Commit**

```bash
git add musicApp/Sync/SyncSessionManager.swift musicApp/ContentView.swift
git commit -m "feat(sync): wire library down-sync dependencies"
```

---

### Task 4: iOS effects-settings sync (`SettingsSync.swift`)

**Files:**
- Create: `musicApp/Sync/SettingsSync.swift`
- Modify: `musicApp/Sync/SyncSessionManager.swift`
- Modify: `musicApp/ContentView.swift`

**Interfaces:**
- Consumes: `AudioPlayerManager.$playbackSpeed` / `$bassBoost` / `$reverbAmount` (existing, `@Published Double`, ranges 0.5–2.0 / -10–20 / 0–100 respectively per `ContentView.swift`'s sliders), `ServerClock.shared.nowMs`, `SyncDevice.id` (existing).
- Produces: `SettingsSync.init(db:player:)`, `.activate(uid:)` — consumed by `SyncSessionManager.attachSettings`.

- [ ] **Step 1: Create `musicApp/Sync/SettingsSync.swift`**

```swift
import Foundation
import Combine
import FirebaseFirestore

/// Two-way effects-settings sync — users/{uid}/sync/settings (singleton
/// doc, same doc family as the session/playlist docs). Twin of
/// desktop/src/settingsSync.ts — FIELD NAMES ARE THE CONTRACT.
///
/// LWW is Firestore's own snapshot ordering (same as SessionState/
/// CloudPlaylist) — `at` (ServerClock ms) is carried for parity/debugging,
/// not compared client-side. `updatedBy` filters same-device echo.
///
/// Speed and bass share units with desktop as-is (multiplier, dB). Reverb is
/// wired 0-100% on the wire; desktop's internal `fx.reverb` is a 0-1
/// fraction, converted at its own sync boundary.
///
/// iOS persists these per-track (`AudioPlayerManager.TrackSettings`), so
/// switching tracks changes the published values as a side effect — that's
/// intentional here: it syncs "whichever effective settings are currently
/// audible", the same way playback state syncs the currently-playing track.
@MainActor
final class SettingsSync {

    private let db: Firestore
    private let player: AudioPlayerManager
    private var bag = Set<AnyCancellable>()
    private var listener: ListenerRegistration?
    private var uid = ""

    // Last values WE applied from a remote snapshot. Lets the local publish
    // sink tell "user moved a slider" apart from "assigning the remote value
    // re-fired @Published" without a timing flag — the publish side is
    // debounced, so a flag would have cleared by the time it fires.
    private var lastAppliedSpeed: Double?
    private var lastAppliedBass: Double?
    private var lastAppliedReverb: Double?

    init(db: Firestore, player: AudioPlayerManager) {
        self.db = db
        self.player = player

        Publishers.CombineLatest3(player.$playbackSpeed, player.$bassBoost, player.$reverbAmount)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] speed, bass, reverb in
                self?.push(speed: speed, bass: bass, reverb: reverb)
            }
            .store(in: &bag)
    }

    func activate(uid: String) {
        self.uid = uid
        listener?.remove()
        listener = docRef.addSnapshotListener { [weak self] snap, _ in
            guard let snap else { return }
            Task { @MainActor in self?.applyRemote(snap) }
        }
    }

    private var docRef: DocumentReference {
        db.collection("users").document(uid).collection("sync").document("settings")
    }

    private func push(speed: Double, bass: Double, reverb: Double) {
        guard !uid.isEmpty else { return }
        if speed == lastAppliedSpeed && bass == lastAppliedBass && reverb == lastAppliedReverb { return }
        let doc: [String: Any] = [
            "speed": speed, "bassDb": bass, "reverbPct": reverb,
            "updatedBy": SyncDevice.id, "at": ServerClock.shared.nowMs,
        ]
        Task { try? await docRef.setData(doc) }
    }

    private func applyRemote(_ snap: DocumentSnapshot) {
        guard let d = snap.data(),
              let by = d["updatedBy"] as? String, by != SyncDevice.id,
              let speed = (d["speed"] as? NSNumber)?.doubleValue,
              let bass = (d["bassDb"] as? NSNumber)?.doubleValue,
              let reverb = (d["reverbPct"] as? NSNumber)?.doubleValue else { return }

        let clampedSpeed = min(max(speed, 0.5), 2.0)
        let clampedBass = min(max(bass, -10), 20)
        let clampedReverb = min(max(reverb, 0), 100)

        lastAppliedSpeed = clampedSpeed
        lastAppliedBass = clampedBass
        lastAppliedReverb = clampedReverb

        player.playbackSpeed = clampedSpeed
        player.bassBoost = clampedBass
        player.reverbAmount = clampedReverb
    }
}
```

- [ ] **Step 2: Add `settingsSync` + `attachSettings` to `SyncSessionManager.swift`**

Add the property next to `private(set) var playlistSync: PlaylistSync?`:

```swift
    private(set) var settingsSync: SettingsSync?
```

Add the activation call in `connect()`, right after `playlistSync?.activate(uid: uid)`:

```swift
        playlistSync?.activate(uid: uid)
        settingsSync?.activate(uid: uid)
```

Add the attach method, after `attachReplication`:

```swift
    /// Wire two-way effects-settings sync:
    ///   sync.attachSettings(player: audioPlayer)
    func attachSettings(player: AudioPlayerManager) {
        settingsSync = SettingsSync(db: coordinator.db, player: player)
        if !uid.isEmpty { settingsSync?.activate(uid: uid) }
    }
```

- [ ] **Step 3: Call it from `ContentView.swift`**

In the same `.onAppear` block as the existing `attachReplication`/`attachPlaylists` calls, add:

```swift
                syncManager.attachSettings(player: audioPlayer)
```

- [ ] **Step 4: Self-review checklist**

- `applyRemote` guards `by != SyncDevice.id` before touching `player.*` — no self-echo application.
- `push` guards on `lastApplied*` equality — a remote-applied value doesn't bounce back as a redundant write.
- Clamp ranges (`0.5...2.0`, `-10...20`, `0...100`) match the sliders in `ContentView.swift:1641,1673,1689` exactly.
- `SettingsSync` is `@MainActor`; the snapshot-listener callback hops via `Task { @MainActor in ... }` before touching `self` — matches `PlaylistSync.swift`'s pattern.

- [ ] **Step 5: Commit**

```bash
git add musicApp/Sync/SettingsSync.swift musicApp/Sync/SyncSessionManager.swift musicApp/ContentView.swift
git commit -m "feat(sync): add iOS effects-settings sync"
```

---

### Task 5: Desktop effects-settings sync (`settingsSync.ts`)

**Files:**
- Create: `desktop/src/settingsSync.ts`

**Interfaces:**
- Consumes: `DEVICE_ID` (`desktop/src/protocol.ts`), `serverClock` (`desktop/src/serverClock.ts`).
- Produces: `class SettingsSync { start(uid); stop(); push(s: SettingsDoc); onRemote?: (s: SettingsDoc) => void }`, `interface SettingsDoc { speed: number; bassDb: number; reverbPct: number }` — consumed by Task 6.

- [ ] **Step 1: Create `desktop/src/settingsSync.ts`**

```ts
// Two-way effects-settings sync — twin of musicApp/Sync/SettingsSync.swift.
// Doc: users/{uid}/sync/settings (singleton, same doc family as session).
//   { speed, bassDb, reverbPct, updatedBy, at }
// LWW is Firestore's own snapshot ordering, same as the session/playlist
// docs — `at` (ServerClock ms) is carried for parity/debugging, not compared
// client-side. `updatedBy` filters same-device echo.
import { Firestore, doc, setDoc, onSnapshot, Unsubscribe } from "firebase/firestore";
import { DEVICE_ID } from "./protocol";
import { serverClock } from "./serverClock";

export interface SettingsDoc {
  speed: number;     // playback rate multiplier
  bassDb: number;     // raw dB, same units both apps
  reverbPct: number;  // 0-100 — desktop's internal fx.reverb is a 0-1 fraction
}

export class SettingsSync {
  onRemote?: (s: SettingsDoc) => void;

  private unsub?: Unsubscribe;
  private uid = "";

  constructor(private db: Firestore) {}

  start(uid: string) {
    this.stop();
    this.uid = uid;
    this.unsub = onSnapshot(this.ref(), snap => {
      const d = snap.data();
      if (!d || d.updatedBy === DEVICE_ID) return;
      if (typeof d.speed !== "number" || typeof d.bassDb !== "number"
          || typeof d.reverbPct !== "number") return;
      this.onRemote?.({ speed: d.speed, bassDb: d.bassDb, reverbPct: d.reverbPct });
    });
  }

  stop() {
    this.unsub?.(); this.unsub = undefined;
    this.uid = "";
  }

  push(s: SettingsDoc) {
    if (!this.uid) return;
    void setDoc(this.ref(), { ...s, updatedBy: DEVICE_ID, at: serverClock.nowMs })
      .catch(() => {});
  }

  private ref() {
    return doc(this.db, "users", this.uid, "sync", "settings");
  }
}
```

- [ ] **Step 2: Typecheck**

Run: `cd desktop; npx tsc --noEmit`
Expected: no errors (this file has no consumers yet — Task 6 wires it in).

- [ ] **Step 3: Commit**

```bash
git add desktop/src/settingsSync.ts
git commit -m "feat(sync): add desktop effects-settings sync"
```

---

### Task 6: Wire desktop settings sync into `ui.ts`

**Files:**
- Modify: `desktop/src/ui.ts`

**Interfaces:**
- Consumes: `SettingsSync`/`SettingsDoc` (Task 5).

- [ ] **Step 1: Import and instantiate**

Add the import next to the `playlists` import (around line 16):

```ts
import { PlaylistSync, CloudPlaylist } from "./playlists";
import { SettingsSync } from "./settingsSync";
```

Add the instance next to `playlistSync` (around line 23):

```ts
const playlistSync = new PlaylistSync(db);
const settingsSync = new SettingsSync(db);
```

- [ ] **Step 2: Start it in `connect()`**

In the `connect` function (around line 75), add right after `playlistSync.start(uid);`:

```ts
  playlistSync.start(uid);
  settingsSync.start(uid);
```

- [ ] **Step 3: Push on slider drag + apply on remote change**

Replace the four effects `bindFx` lines (around line 202-205):

```ts
  bindFx("fx-volume", v => { fx.volume = v / 100; });
  bindFx("fx-speed", v => { fx.speed = v / 100; }, true);
  bindFx("fx-bass", v => { fx.bass = v; });
  bindFx("fx-reverb", v => { fx.reverb = v / 100; });
```

with:

```ts
  bindFx("fx-volume", v => { fx.volume = v / 100; });
  bindFx("fx-speed", v => { fx.speed = v / 100; pushSettingsDebounced(); }, true);
  bindFx("fx-bass", v => { fx.bass = v; pushSettingsDebounced(); });
  bindFx("fx-reverb", v => { fx.reverb = v / 100; pushSettingsDebounced(); });

  settingsSync.onRemote = s => {
    fx.speed = Math.min(Math.max(s.speed, 0.5), 2.0);
    fx.bass = Math.min(Math.max(s.bassDb, 0), 12);
    fx.reverb = Math.min(Math.max(s.reverbPct, 0), 100) / 100;
    initFxSliders(); // updates slider DOM values + calls applyFx()
  };
```

- [ ] **Step 4: Add the debounce helper**

Add next to the `FX_KEY`/`fx` declarations (around line 230, right before `function applyFx`):

```ts
let settingsPushTimer: ReturnType<typeof setTimeout> | null = null;
function pushSettingsDebounced() {
  if (settingsPushTimer) clearTimeout(settingsPushTimer);
  settingsPushTimer = setTimeout(() => {
    settingsSync.push({ speed: fx.speed, bassDb: fx.bass, reverbPct: fx.reverb * 100 });
  }, 300);
}
```

- [ ] **Step 5: Typecheck**

Run: `cd desktop; npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 6: Self-review**

- Bass clamp on receive is `0...12` (desktop's slider range, `desktop/index.html:398`), not iOS's `-10...20` — receiving side clamps to its own range, per design doc.
- `reverbPct` is divided by 100 exactly once, at the point it's assigned into the internal 0-1 `fx.reverb` — no double conversion.
- `initFxSliders()` (existing function, unchanged) both updates the slider DOM `.value`s and calls `applyFx()` — confirmed by reading its body, so the remote-apply path doesn't need its own DOM-update code.

- [ ] **Step 7: Commit**

```bash
git add desktop/src/ui.ts
git commit -m "feat(sync): wire effects-settings sync into desktop UI"
```

---

### Task 7: Manual end-to-end verification

No automated test harness exists for either app reachable from this machine (no Xcode on Windows; desktop has no test runner, only `tsc`). This task is the real functional check, run with two physical clients per the design doc's Testing section.

**Files:** none (manual QA only).

- [ ] **Step 1: Build**

- Desktop: `cd desktop; npm run build` (confirms bundling succeeds, not just typecheck).
- iOS: tell the user to open the project in Xcode on their Mac and build.

- [ ] **Step 2: Library down-sync (workstream A)**

- On desktop only, download a song (paste a YouTube link). Confirm it appears downloaded on the phone without touching the phone.
- Reverse: download a song on the phone only. Confirm it appears on desktop.
- Confirm no duplicate entries appear in either library after either direction.

- [ ] **Step 3: Effects settings sync (workstream B)**

- While both devices are connected, drag the speed/bass/reverb sliders on one device. Confirm the other device's slider and actual playback effect move to match within ~1s.
- Drag on device A while device B is mid-drag. Confirm last-write-wins with no oscillation between the two values.

- [ ] **Step 4: Report results to the user**

Summarize pass/fail for each of the four checks above before considering this plan complete.
