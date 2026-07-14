# Sync Completeness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every device is an equal citizen of the home session: iOS becomes a live remote when another device owns playback (with a clear "switch to this iPhone" pill), desktop downloads prioritize audio quality, and track metadata (renames, crops, folders, deletions) syncs across all devices, plus lyric-offset freshness.

**Architecture:** Two codebases sharing a Firestore wire format: the iOS app (`musicApp/`, Swift/SwiftUI) and the Electron desktop app (`desktop/`, TypeScript). The sync backbone already exists — `CommandBus` (follower→owner transport commands), `PlaybackSyncEngine`/`SyncEngine` (state reconciliation), `LibraryReplicator`/`Replicator` (link-sync library mirror: metadata docs only, each device downloads its own audio via yt-dlp). This plan adds UI on iOS, makes the per-track library doc mutable, and teaches desktop about crops.

**Tech Stack:** Swift/SwiftUI + Firebase iOS SDK; TypeScript + Electron + firebase JS SDK; yt-dlp on both.

**Spec:** `docs/superpowers/specs/2026-07-13-ios-remote-playback-control-design.md` — read it before starting.

## Global Constraints

- **No stock iOS controls.** Every control is custom-themed via `Theme.swift` (`PillButtonStyle`, `CircleControlButtonStyle`, `ThemedSlider`, …). Never introduce a bare SwiftUI `Button` style, `Slider`, or `Menu`.
- **Wire format is a contract.** Field names in `desktop/src/protocol.ts` and `musicApp/Sync/SyncModels.swift` must change in lockstep. Both files say so in their headers.
- **iOS cannot be compiled in this environment** (no Xcode/macOS). Swift tasks are verified by careful re-reading against the step's code and by the manual test matrix in the spec. Do not claim a Swift build passed.
- **Desktop verification command:** `cd desktop && npm run build` (tsc typecheck + esbuild bundle). It must exit 0 after every desktop task.
- **A follower must never start local audio** except via the existing takeover paths (`takeOverHere`, implicit takeover on local play).
- **iOS yt-dlp format stays** `'140/bestaudio[ext=m4a]/bestaudio/best'` (space-saving is deliberate). Only desktop changes format.
- **Folder authority is desktop.** iOS never writes the `folder` field; it only displays it.
- Commit after every task with the message given in the task.

---

### Task 1: iOS engine remote-mode API + SyncSessionManager observability

**Files:**
- Modify: `musicApp/Sync/PlaybackSyncEngine.swift` (`handleRemote` ~line 97, `route` ~line 364, class properties ~line 34)
- Modify: `musicApp/Sync/SyncSessionManager.swift` (init, ~line 35)

**Interfaces:**
- Consumes: existing `SessionCoordinator.role/.remote`, `ServerClock.shared.nowMs`, `PlaybackState.positionMs(atServerMs:)`, `TrackResolving.resolve`.
- Produces (used by Tasks 2–3): `PlaybackSyncEngine.isRemoteControlled: Bool`, `PlaybackSyncEngine.mirrorTrack: Track?` (`@Published`), optimistic mirror patching inside `requestPlay/Pause/Seek`, and `SyncSessionManager` re-publishing nested `objectWillChange` so views observing `syncManager` re-render on role/mirror changes.

- [ ] **Step 1: Add `isRemoteControlled` and `mirrorTrack` to PlaybackSyncEngine**

Below the existing `@Published private(set) var ghostQueue` declaration add:

```swift
    /// Remote track resolved against the local library — gives remote-mode UI
    /// artwork/file paths without exposing the resolver. nil while a track is
    /// playing remotely = ghost (not replicated to this device yet).
    @Published private(set) var mirrorTrack: Track?

    /// Another device currently owns the shared session — views become a live
    /// remote (mirror display + command-bus controls) while this is true.
    var isRemoteControlled: Bool {
        coordinator.role == .follower &&
        !(coordinator.remote?.ownerDeviceID.isEmpty ?? true)
    }
```

In `handleRemote(_:)`, directly after `mirror = state.playback`, add:

```swift
        mirrorTrack = state.playback.track.flatMap { resolver.resolve($0) }
```

- [ ] **Step 2: Optimistic mirror patching in the follower command path**

Replace the existing `route(_:)`:

```swift
    private func route(_ cmd: SyncCommand) {
        if coordinator.role.isOwner {
            applyCommand(cmd)
        } else {
            commands.send(cmd)
            patchMirror(cmd)
        }
    }

    /// Optimistic follower echo — twin of desktop ui.ts toggleCmd/seekCmd.
    /// A command round-trips 0.7–2 s; patch the mirror immediately so the UI
    /// responds now. The next authoritative snapshot replaces the whole mirror
    /// (handleRemote overwrites it), so no rollback logic is needed.
    private func patchMirror(_ cmd: SyncCommand) {
        guard var pb = mirror else { return }
        let now = ServerClock.shared.nowMs
        switch cmd {
        case .play:
            pb.positionMs = pb.positionMs(atServerMs: now)
            pb.anchorMs = now
            pb.isPlaying = true
        case .pause:
            pb.positionMs = pb.positionMs(atServerMs: now)
            pb.anchorMs = now
            pb.isPlaying = false
        case .seek(let ms):
            pb.positionMs = ms
            pb.anchorMs = now
        case .next, .previous:
            return  // target track unknown until the owner's snapshot arrives
        }
        mirror = pb
    }
```

- [ ] **Step 3: Forward nested objectWillChange in SyncSessionManager**

Nested `ObservableObject`s don't propagate through `@ObservedObject var syncManager`. Add to `SyncSessionManager`:

```swift
    private var forwarding = Set<AnyCancellable>()
```

and at the END of `init(player:library:)`:

```swift
        // Views observe syncManager; changes actually happen on the nested
        // coordinator/engine. Forward their objectWillChange so role flips and
        // mirror updates re-render SwiftUI without each view observing both.
        coordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarding)
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarding)
```

- [ ] **Step 4: Self-verify**

Re-read the diff: `mirror` must remain `@Published private(set)`, `patchMirror` must be `@MainActor`-safe (whole class already is), `Combine` is already imported in both files. No other call sites of `route` exist.

- [ ] **Step 5: Commit**

```bash
git add musicApp/Sync/PlaybackSyncEngine.swift musicApp/Sync/SyncSessionManager.swift
git commit -m "sync: engine remote-mode API (mirrorTrack, optimistic patch, observability)"
```

---

### Task 2: iOS MiniPlayerBar remote mode

**Files:**
- Modify: `musicApp/ContentView.swift` — mini bar visibility (~line 125), `MiniPlayerBar` struct (~lines 444–616)

**Interfaces:**
- Consumes: Task 1's `engine.isRemoteControlled`, `engine.mirror`, `engine.mirrorTrack`, `engine.requestPlay()/requestPause()/requestNext()`.
- Produces: `MiniPlayerBar(audioPlayer:downloadManager:syncManager:showNowPlaying:)` — new `syncManager` parameter; callsite updated in the same task.

- [ ] **Step 1: Widen the visibility condition (ContentView body, ~line 125)**

```swift
                if audioPlayer.currentTrack != nil || syncManager.engine.isRemoteControlled {
                    // Slim "next song" bar nested above the mini player. Renders
                    // nothing when there's no next track, so the mini bar sits
                    // alone in that case.
                    UpNextMiniBar(audioPlayer: audioPlayer, downloadManager: downloadManager)
                    MiniPlayerBar(audioPlayer: audioPlayer, downloadManager: downloadManager,
                                  syncManager: syncManager, showNowPlaying: $showNowPlaying)
                }
```

(`UpNextMiniBar` needs no changes — a follower's local queue is already mirrored, so it shows the correct next track, and tapping it plays locally = the existing implicit takeover.)

- [ ] **Step 2: Add remote-mode state and helpers to MiniPlayerBar**

Add the property after `downloadManager`:

```swift
    @ObservedObject var syncManager: SyncSessionManager
```

Add helpers below the existing `progress` computed property:

```swift
    private var isRemote: Bool { syncManager.engine.isRemoteControlled }
    private var remotePB: PlaybackState? { syncManager.engine.mirror }
    /// Local track when playing here; resolved remote track when following.
    private var activeTrack: Track? {
        isRemote ? syncManager.engine.mirrorTrack : audioPlayer.currentTrack
    }
    private var displayName: String {
        isRemote ? (remotePB?.track?.name ?? "Unknown")
                 : (audioPlayer.currentTrack?.name ?? "Unknown")
    }
    private var displayFolder: String {
        isRemote ? (remotePB?.track?.folder ?? "")
                 : (audioPlayer.currentTrack?.folderName ?? "")
    }
    private var displayIsPlaying: Bool {
        isRemote ? (remotePB?.isPlaying ?? false) : audioPlayer.isPlaying
    }
    private func remoteProgress(atMs now: Int) -> CGFloat {
        guard let pb = remotePB, pb.durationMs > 0 else { return 0 }
        let pos = Double(pb.positionMs(atServerMs: now))
        return CGFloat(min(max(pos / Double(pb.durationMs), 0), 1))
    }
```

- [ ] **Step 3: Swap display sources in the bar's body**

- `refreshThumbnailPath()`: change `guard let track = audioPlayer.currentTrack` to `guard let track = activeTrack`.
- `updateBackgroundImage()`: change `guard let track = audioPlayer.currentTrack` to `guard let track = activeTrack`, and the staleness check `if self.audioPlayer.currentTrack?.url == audioURL` to `if self.activeTrack?.url == audioURL`.
- `AsyncThumbnailView(...).id(audioPlayer.currentTrack?.id)` → `.id(activeTrack?.id ?? remotePB?.track?.id)`.
- Title text `audioPlayer.currentTrack?.name ?? "Unknown"` → `displayName`.
- Folder text `(audioPlayer.currentTrack?.folderName ?? "")` → `displayFolder`.
- Both `.onChange(of: audioPlayer.currentTrack?.id)` → `.onChange(of: activeTrack?.id)`.

Add a remote badge inside the title `VStack`, on the folder line, replacing the plain `Text` with:

```swift
                        HStack(spacing: 5) {
                            if isRemote {
                                Image(systemName: "laptopcomputer.and.iphone")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Theme.redLight.opacity(0.9))
                            }
                            Text(displayFolder.uppercased())
                                .font(Theme.eyebrowFont)
                                .tracking(1.2)
                                .foregroundColor(Theme.bone.opacity(0.7))
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.3), radius: 2)
                        }
```

- [ ] **Step 4: Route transport buttons**

Play/pause button action becomes:

```swift
                Button {
                    if isRemote {
                        if displayIsPlaying { syncManager.engine.requestPause() }
                        else { syncManager.engine.requestPlay() }
                    } else if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                } label: {
                    Image(systemName: displayIsPlaying ? "pause.fill" : "play.fill")
```

(keep the existing label modifiers). Next button action:

```swift
                Button {
                    if isRemote { syncManager.engine.requestNext() }
                    else { audioPlayer.next() }
                } label: {
```

- [ ] **Step 5: Ticking progress hairline**

Factor the hairline and branch the overlay. Replace the existing `.overlay(alignment: .bottomLeading) { GeometryReader { … } }` with:

```swift
        .overlay(alignment: .bottomLeading) {
            if isRemote {
                // No local player ticks while following — extrapolate from the
                // mirror on a visible-only 0.5 s timeline.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    progressHairline(remoteProgress(atMs: ServerClock.shared.nowMs))
                }
            } else {
                progressHairline(progress)
            }
        }
```

and add:

```swift
    private func progressHairline(_ p: CGFloat) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(Theme.emberGradient)
                .frame(width: max(geo.size.width * p, 0), height: 2.5)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
```

- [ ] **Step 6: Self-verify**

Re-read: no remaining direct `audioPlayer.currentTrack` reads inside `MiniPlayerBar` except via `activeTrack`; the tap-to-open-NowPlaying gesture unchanged; the only new callsite parameter is `syncManager` and ContentView passes it.

- [ ] **Step 7: Commit**

```bash
git add musicApp/ContentView.swift
git commit -m "ios: mini player becomes a live remote when another device owns playback"
```

---

### Task 3: iOS NowPlayingView live remote + switch pill

**Files:**
- Modify: `musicApp/ContentView.swift` — `NowPlayingView` (~lines 619–1330): body (~669–724), `remoteLockOverlay` (~870–904), `topBar` (~906–978), `thumbnailView` (~980–1004), `controlsSection` (~1006–1016), `titleView` (~1091–1145), `progressBar` (~1147–1186), `playbackControls` (~1188–1219), `sliderBinding` (~650–660), refresh helpers (`updateBackgroundImage` ~1237, `refreshThumbnailImage` ~1268, `refreshTitleMetrics`), `onAppear` (~725).

**Interfaces:**
- Consumes: Task 1's engine API; existing `syncManager.playHere()`, `SessionState.leaseExpired`, `PillButtonStyle`, `CircleControlButtonStyle`, `ThemedSlider`.
- Produces: user-visible remote control; no new API.

- [ ] **Step 1: Delete the lock**

In `body` remove these two modifiers from the foreground `VStack`:

```swift
                .blur(radius: isRemoteControlled ? 18 : 0)
                .allowsHitTesting(!isRemoteControlled)
```

Remove the block:

```swift
                if isRemoteControlled {
                    remoteLockOverlay
                }
```

Delete the whole `remoteLockOverlay` `@ViewBuilder` property (~lines 870–904). Keep the `switchingHere` `@State` — the pill reuses it.

- [ ] **Step 2: Display-source helpers**

Replace the existing `isRemoteControlled` computed property with:

```swift
    /// Another device currently owns the shared session — this screen is a
    /// live remote for it (controls route through the command bus).
    private var isRemoteControlled: Bool { syncManager.engine.isRemoteControlled }

    private var engine: PlaybackSyncEngine { syncManager.engine }
    /// Local track normally; resolved remote track in remote mode (nil = ghost).
    private var displayTrack: Track? {
        isRemoteControlled ? engine.mirrorTrack : audioPlayer.currentTrack
    }
    private var displayName: String {
        isRemoteControlled ? (engine.mirror?.track?.name ?? "Unknown")
                           : (audioPlayer.currentTrack?.name ?? "Unknown")
    }
    private var displayIsPlaying: Bool {
        isRemoteControlled ? (engine.mirror?.isPlaying ?? false) : audioPlayer.isPlaying
    }
    private var displayDuration: Double {
        isRemoteControlled ? Double(engine.mirror?.durationMs ?? 0) / 1000.0
                           : audioPlayer.duration
    }
    private func displayPosition(atMs now: Int) -> Double {
        isRemoteControlled
            ? Double(engine.mirror?.positionMs(atServerMs: now) ?? 0) / 1000.0
            : audioPlayer.currentTime
    }
    private func togglePlayPause() {
        if isRemoteControlled {
            if displayIsPlaying { engine.requestPause() } else { engine.requestPlay() }
        } else if audioPlayer.isPlaying {
            audioPlayer.pause()
        } else {
            audioPlayer.resume()
        }
    }
```

- [ ] **Step 3: The switch pill, directly below the top bar**

In `body`'s foreground `VStack(spacing: 0)`, insert right after `topBar`:

```swift
                    topBar

                    if isRemoteControlled { switchHerePill }
```

Add the builders:

```swift
    private var ownerReachable: Bool {
        !(syncManager.coordinator.remote?.leaseExpired ?? false)
    }
    /// Remote track exists but can't resolve locally — switching would claim
    /// the session and play silence, so the pill disables instead.
    private var mirrorTrackIsGhost: Bool {
        engine.mirror?.track != nil && engine.mirrorTrack == nil
    }

    @ViewBuilder
    private var switchHerePill: some View {
        VStack(spacing: 8) {
            Text(mirrorTrackIsGhost ? "Not in this device's library yet"
                 : ownerReachable ? "Playing on another device"
                 : "Other device offline")
                .font(Theme.caption(12))
                .foregroundColor(Theme.boneDim)
            Button {
                switchingHere = true
                Task {
                    defer { switchingHere = false }
                    try? await syncManager.playHere()
                }
            } label: {
                Text(switchingHere ? "Switching…" : "Switch playback to this iPhone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(switchingHere || mirrorTrackIsGhost)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
    }
```

- [ ] **Step 4: Transport controls route remotely**

In `playbackControls`:
- previous: `Button { if isRemoteControlled { engine.requestPrevious() } else { audioPlayer.previous() } }`
- next: `Button { if isRemoteControlled { engine.requestNext() } else { audioPlayer.next() } }`
- play/pause action body → `togglePlayPause()`, icon → `displayIsPlaying ? "pause.fill" : "play.fill"`.
- `RewindButton`/`FastForwardButton` drive the local player; branch them:

```swift
            if isRemoteControlled {
                Button {
                    let now = ServerClock.shared.nowMs
                    let pos = engine.mirror?.positionMs(atServerMs: now) ?? 0
                    engine.requestSeek(ms: max(0, pos - 10_000))
                } label: { Image(systemName: "gobackward.10") }
                .buttonStyle(CircleControlButtonStyle(diameter: 46, tint: Theme.bone))
            } else {
                RewindButton(audioPlayer: audioPlayer)
            }
```

and the mirror-image forward version (`"goforward.10"`, `pos + 10_000`, no `max`) replacing `FastForwardButton`.

In `thumbnailView`, the `onTap` closure body becomes `togglePlayPause()`. In `titleView`, the `.onTapGesture` body becomes `togglePlayPause()`; the long-press rename gate becomes `if let track = displayTrack` (rename works on any locally-resolved track via `downloadManager`); the crop badge condition becomes `if let track = displayTrack, track.cropStartTime != nil || track.cropEndTime != nil`.

- [ ] **Step 5: Seek slider + times from the right source**

Delete the `sliderBinding` property and replace `progressBar` with:

```swift
    @ViewBuilder
    private var progressBar: some View {
        if isRemoteControlled {
            // Mirror position needs its own tick — no local player updates
            // arrive while following. Visible-only 0.5 s timeline.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                progressBarBody(
                    position: isSeeking ? localSeekPosition
                                        : displayPosition(atMs: ServerClock.shared.nowMs),
                    duration: displayDuration,
                    rate: Double(engine.mirror?.rateX1000 ?? 1000) / 1000.0)
            }
        } else {
            progressBarBody(
                position: isSeeking ? localSeekPosition : audioPlayer.currentTime,
                duration: audioPlayer.duration,
                rate: audioPlayer.effectivePlaybackSpeed)
        }
    }

    private func progressBarBody(position: Double, duration: Double, rate: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Spacer()
                Text("-" + formatTime((duration - position) / max(rate, 0.01)))
                    .font(Theme.caption(12).monospacedDigit())
                    .foregroundColor(Theme.bone.opacity(0.7))
            }

            ThemedSlider(
                value: Binding(
                    get: { isSeeking ? localSeekPosition : position },
                    set: { newValue in
                        localSeekPosition = newValue
                        if !isSeeking { commitSeek(to: newValue) }
                    }
                ),
                range: 0...max(duration, 1),
                tint: Theme.redLight
            ) { editing in
                isSeeking = editing
                if editing {
                    localSeekPosition = position
                } else {
                    commitSeek(to: localSeekPosition)
                }
            }
            .disabled(duration == 0)

            HStack {
                Text(formatTime(position))
                    .font(Theme.caption(12).monospacedDigit())
                    .foregroundColor(Theme.bone.opacity(0.7))
                Spacer()
                Text(formatTime(duration))
                    .font(Theme.caption(12).monospacedDigit())
                    .foregroundColor(Theme.bone.opacity(0.7))
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
    }

    private func commitSeek(to seconds: Double) {
        if isRemoteControlled {
            engine.requestSeek(ms: Int(seconds * 1000))  // optimistic patch lands via Task 1
        } else {
            audioPlayer.seek(to: seconds)
        }
    }
```

- [ ] **Step 6: Hide volume + skip visualizer in remote mode**

In `controlsSection` wrap the volume bar: `if !isRemoteControlled { volumeBar }`.
In `onAppear`, change `audioPlayer.startVisualization()` to:

```swift
            if !isRemoteControlled { audioPlayer.startVisualization() }
```

(no local audio → nothing to visualize; the artwork still shows).

- [ ] **Step 7: Point every remaining NowPlayingView read at displayTrack**

Mechanical rule, applied ONLY inside `NowPlayingView`: every remaining read of `audioPlayer.currentTrack` becomes `displayTrack`, and reads of its `.name` for display become `displayName`. Known sites:
- `updateBackgroundImage()` — `guard let track = displayTrack`; keep the rest identical.
- `refreshThumbnailImage()` (~line 1268): `cachedNowPlayingThumbnail = getThumbnailImage(for: displayTrack)`.
- `refreshTitleMetrics()`: source string becomes `displayName`.
- Every `.onChange(of: audioPlayer.currentTrack?.id)` → `.onChange(of: displayTrack?.id)`.
- Sheet parameters (lyrics `load(track:)`, `AddToPlaylistSheet`, `CropSongSheet`, rename alert seed) that pass `audioPlayer.currentTrack` pass `displayTrack` instead; the top-bar loop button gets `.disabled(isRemoteControlled)` (loop is a local-player flag — meaningless while following, same as desktop).

Transport/seek paths were already handled in Steps 4–5; do not change code outside `NowPlayingView`.

- [ ] **Step 8: Self-verify**

Search `NowPlayingView` for `audioPlayer.currentTrack` — remaining hits must be zero (all flow through `displayTrack`). Search for `remoteLockOverlay` — zero hits. Confirm `switchingHere` still declared, `PlaybackState` fields used are `durationMs`/`rateX1000`/`positionMs(atServerMs:)` exactly as defined in `SyncModels.swift:118-135`.

- [ ] **Step 9: Commit**

```bash
git add musicApp/ContentView.swift
git commit -m "ios: Now Playing is a live remote with a switch-to-this-iPhone pill"
```

---

### Task 4: Desktop download quality

**Files:**
- Modify: `desktop/src/download.ts:84` and header comment (lines 7–9)

**Interfaces:** none — behavior-only change.

- [ ] **Step 1: Change the format selector**

Line 84, replace:

```ts
    "-f", "bestaudio[ext=m4a]/bestaudio",
```

with:

```ts
    // Quality over space on desktop (iOS deliberately keeps 128 kbps m4a for
    // space): plain bestaudio picks the highest-abr stream YouTube serves,
    // typically ~160 kbps VBR Opus in webm — Chromium + the scanner already
    // handle opus/webm natively.
    "-f", "bestaudio",
```

Update the header comment lines 7–8 from "bestaudio in its native container (m4a/webm/opus)" context so it no longer implies an m4a preference — replace the sentence `No ffmpeg dependency: bestaudio in its native container (m4a/webm/opus), all of which the scanner + Chromium already handle.` with `No ffmpeg dependency: bestaudio in its native container — highest-abr stream, usually opus/webm — which the scanner + Chromium already handle.`

- [ ] **Step 2: Verify**

Run: `cd desktop && npm run build` — expect exit 0.

- [ ] **Step 3: Commit**

```bash
git add desktop/src/download.ts
git commit -m "desktop: prioritize audio quality for yt-dlp downloads"
```

---

### Task 5: Wire format — mutable TrackMeta on both platforms

**Files:**
- Modify: `desktop/src/protocol.ts:44-55` (`TrackMeta`)
- Modify: `musicApp/Sync/SyncModels.swift:77-96` (`TrackMeta`)

**Interfaces:**
- Produces (used by Tasks 6–9): fields `cropStartMs?: number`, `cropEndMs?: number`, `deleted?: boolean`, `metaAt` (server timestamp), `metaBy?: string` on the library doc; Swift `TrackMeta` gains `cropStartMs: Int?`, `cropEndMs: Int?`, `deleted: Bool` (default false), `metaBy: String?`.

- [ ] **Step 1: protocol.ts**

Extend the interface:

```ts
export interface TrackMeta {
  name: string;
  folder: string;
  yt?: string;
  ext: string;
  path?: string;
  by: string;
  // Mutable metadata (sync-completeness, 2026-07). Absent on legacy docs.
  // LWW: last metadata writer wins; metaBy breaks echo loops (a device
  // ignores changes it authored). Folder authority is DESKTOP — iOS never
  // writes `folder`, only displays it.
  cropStartMs?: number;  // crop window start ms — playback metadata, file untouched
  cropEndMs?: number;
  deleted?: boolean;     // revivable tombstone: re-mirroring the same yt revives the doc
  metaAt?: unknown;      // serverTimestamp of the last metadata write
  metaBy?: string;       // device id of the last metadata writer
}
```

- [ ] **Step 2: SyncModels.swift**

Replace the `TrackMeta` struct with:

```swift
struct TrackMeta {
    let name: String
    let folder: String
    let yt: String?
    let ext: String
    let by: String
    // Mutable metadata — absent on legacy docs. LWW via last write; metaBy
    // breaks echo loops. Folder authority is desktop; iOS displays only.
    let cropStartMs: Int?
    let cropEndMs: Int?
    let deleted: Bool
    let metaBy: String?

    init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String,
              let folder = dict["folder"] as? String,
              let ext = dict["ext"] as? String,
              let by = dict["by"] as? String else { return nil }
        self.name = name; self.folder = folder; self.ext = ext; self.by = by
        self.yt = dict["yt"] as? String
        self.cropStartMs = dict["cropStartMs"] as? Int
        self.cropEndMs = dict["cropEndMs"] as? Int
        self.deleted = dict["deleted"] as? Bool ?? false
        self.metaBy = dict["metaBy"] as? String
    }
}
```

- [ ] **Step 3: Verify + commit**

`cd desktop && npm run build` — exit 0 (interface-only change; no consumers yet).

```bash
git add desktop/src/protocol.ts musicApp/Sync/SyncModels.swift
git commit -m "sync: mutable TrackMeta wire format (crop, tombstone, LWW stamps)"
```

---

### Task 6: iOS DownloadManager metadata hooks

**Files:**
- Modify: `musicApp/Download.swift` (add `folderOverride`)
- Modify: `musicApp/DownloadManager.swift` (`renameDownload` ~880, `updateCropTimes` ~985, `confirmDeletion` ~1274; new members)
- Modify: `musicApp/ContentView.swift:36-44` (library closure folder)

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Task 7):
  - `DownloadManager.trackMetaChanged: PassthroughSubject<Download, Never>` — fires on user rename/crop.
  - `DownloadManager.trackDeleted: PassthroughSubject<Download, Never>` — fires when a local deletion is confirmed.
  - `DownloadManager.applyRemoteMeta(videoID:name:folder:cropStartMs:cropEndMs:)` — applies without re-firing.
  - `DownloadManager.removeDownloadFromSync(videoID:)` — applies a remote deletion without re-firing.
  - `Download.folderOverride: String?` — display folder from the cloud doc.
  - `renameDownload(_:newName:fromSync:)` and `updateCropTimes(for:startTime:endTime:fromSync:)` — `fromSync` defaults `false`.

- [ ] **Step 1: Download model**

In `Download.swift` add alongside `cropEndTime`:

```swift
    /// Display folder from the cloud doc (desktop is the folder authority);
    /// iOS never moves files — this only groups/labels them in the UI.
    var folderOverride: String?
```

`Download` is `Codable` with synthesized coding — an optional new property decodes as `nil` from old JSON. If the struct declares explicit `CodingKeys`, add `case folderOverride` and decode with `decodeIfPresent`.

- [ ] **Step 2: Publishers + fromSync flags**

In `DownloadManager` (imports already include Combine via `@Published` usage — add `import Combine` if missing) add:

```swift
    /// Fired when the USER renames or crops a track here (not for sync-applied
    /// changes) — LibraryReplicator pushes these to the cloud doc.
    let trackMetaChanged = PassthroughSubject<Download, Never>()
    /// Fired when a local deletion is confirmed (undo grace elapsed).
    let trackDeleted = PassthroughSubject<Download, Never>()
```

Change signatures:

```swift
    func renameDownload(_ download: Download, newName: String, fromSync: Bool = false) {
```

and at the end of its success path (after the currently-playing update, still inside `do`):

```swift
            if !fromSync { trackMetaChanged.send(downloads[index]) }
```

```swift
    func updateCropTimes(for trackID: UUID, startTime: Double?, endTime: Double?, fromSync: Bool = false) {
```

and at the end of the function:

```swift
        if !fromSync, let i = downloads.firstIndex(where: { $0.id == trackID }) {
            trackMetaChanged.send(downloads[i])
        }
```

- [ ] **Step 3: Deletion refactor**

Extract the body of `confirmDeletion` (file removal, thumbnail removal, metadata-JSON update, `downloads.removeAll`, timer cleanup, `saveDownloads()`, and whatever follows through `notifyChange()`) into:

```swift
    private func performDeletion(_ download: Download) {
        // (moved body of confirmDeletion, minus the onDelete callback)
    }
```

`confirmDeletion` becomes:

```swift
    private func confirmDeletion(_ download: Download, onDelete: @escaping (Download) -> Void) {
        onDelete(download)
        performDeletion(download)
        trackDeleted.send(download)
    }
```

Add the remote-apply entry points:

```swift
    /// Deletion that originated on another device: no undo grace (it already
    /// ran on the deleting device) and no trackDeleted echo back to the cloud.
    func removeDownloadFromSync(videoID: String) {
        guard let download = downloads.first(where: { $0.videoID == videoID }) else { return }
        // Stop playback of the vanishing track before its file goes away.
        if let audioPlayer, audioPlayer.currentTrack?.id == download.id {
            if audioPlayer.upNextTracks.isEmpty { audioPlayer.pause() }
            else { audioPlayer.next() }
        }
        timerLock.lock()
        deletionTimers[download.id]?.invalidate()
        deletionTimers.removeValue(forKey: download.id)
        timerLock.unlock()
        performDeletion(download)
    }

    /// Remote rename/crop/folder — applies without re-publishing (fromSync).
    func applyRemoteMeta(videoID: String, name: String, folder: String,
                         cropStartMs: Int?, cropEndMs: Int?) {
        guard let download = downloads.first(where: { $0.videoID == videoID }) else { return }
        if download.name != name {
            renameDownload(download, newName: name, fromSync: true)
        }
        guard let i = downloads.firstIndex(where: { $0.videoID == videoID }) else { return }
        let newStart = cropStartMs.map { Double($0) / 1000.0 }
        let newEnd = cropEndMs.map { Double($0) / 1000.0 }
        if downloads[i].cropStartTime != newStart || downloads[i].cropEndTime != newEnd {
            updateCropTimes(for: downloads[i].id, startTime: newStart,
                            endTime: newEnd, fromSync: true)
        }
        if !folder.isEmpty, downloads[i].folderOverride != folder {
            downloads[i].folderOverride = folder
            saveDownloads()
            notifyChange()
        }
    }
```

(If `audioPlayer` is not an existing property/name in `DownloadManager`, use the same reference `renameDownload` uses at ~line 954 — `self.audioPlayer`.)

- [ ] **Step 4: Display the folder override**

`ContentView.swift` library closure (~line 39):

```swift
                downloads.downloads.map {
                    Track(id: $0.id, name: $0.name, url: $0.url,
                          folderName: $0.folderOverride ?? "YouTube Downloads",
                          cropStartTime: $0.cropStartTime, cropEndTime: $0.cropEndTime)
                }
```

- [ ] **Step 5: Self-verify + commit**

Check: every existing caller of `renameDownload`/`updateCropTimes` compiles unchanged (new parameter is defaulted). `performDeletion` contains ALL the removal work exactly once.

```bash
git add musicApp/Download.swift musicApp/DownloadManager.swift musicApp/ContentView.swift
git commit -m "ios: download metadata hooks (rename/crop publishers, sync-applied deletes, folder override)"
```

---

### Task 7: iOS LibraryReplicator metadata sync

**Files:**
- Modify: `musicApp/Sync/LibraryReplicator.swift` (init ~39, `activate` ~66, `handleSnapshot` ~87, `upload` ~166, new methods)
- Modify: `musicApp/Sync/SyncSessionManager.swift:106-114` (`attachReplication`)
- Modify: `musicApp/ContentView.swift:89-97` (wiring)

**Interfaces:**
- Consumes: Task 5's `TrackMeta` fields; Task 6's publishers and apply methods.
- Produces: bidirectional metadata sync on iOS. New `attachReplication` signature (single callsite):

```swift
    func attachReplication(downloads: AnyPublisher<[Download], Never>,
                           failedDownloads: AnyPublisher<[FailedDownload], Never>,
                           metaChanges: AnyPublisher<Download, Never>,
                           deletions: AnyPublisher<Download, Never>,
                           findDuplicate: @escaping (String) -> Download?,
                           startDownload: @escaping (String, String, DownloadSource, String) -> Void,
                           applyMeta: @escaping (String, TrackMeta) -> Void,
                           applyDeletion: @escaping (String) -> Void)
```

- [ ] **Step 1: Thread the new dependencies**

`LibraryReplicator.init` gains the four new parameters (`metaChanges`, `deletions`, `applyMeta`, `applyDeletion`), stored as:

```swift
    private let applyMeta: (String, TrackMeta) -> Void
    private let applyDeletion: (String) -> Void
```

and subscribed in init:

```swift
        metaChanges
            .sink { [weak self] d in self?.pushMeta(for: d) }
            .store(in: &bag)
        deletions
            .sink { [weak self] d in self?.pushTombstone(for: d) }
            .store(in: &bag)
```

`SyncSessionManager.attachReplication` passes them straight through. `ContentView` `onAppear` wiring becomes:

```swift
                syncManager.attachReplication(
                    downloads: downloadManager.$downloads.eraseToAnyPublisher(),
                    failedDownloads: downloadManager.$failedDownloads.eraseToAnyPublisher(),
                    metaChanges: downloadManager.trackMetaChanged.eraseToAnyPublisher(),
                    deletions: downloadManager.trackDeleted.eraseToAnyPublisher(),
                    findDuplicate: { [weak downloadManager] yt in
                        downloadManager?.findDuplicateByVideoID(videoID: yt, source: .youtube)
                    },
                    startDownload: { [weak downloadManager] url, yt, source, title in
                        downloadManager?.startBackgroundDownload(url: url, videoID: yt, source: source, title: title)
                    },
                    applyMeta: { [weak downloadManager] yt, m in
                        downloadManager?.applyRemoteMeta(videoID: yt, name: m.name, folder: m.folder,
                                                         cropStartMs: m.cropStartMs, cropEndMs: m.cropEndMs)
                    },
                    applyDeletion: { [weak downloadManager] yt in
                        downloadManager?.removeDownloadFromSync(videoID: yt)
                    })
```

- [ ] **Step 2: Push methods (local intent → doc merge)**

Add to `LibraryReplicator`:

```swift
    // MARK: - Metadata push (user rename/crop/delete here → cloud doc)

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
```

- [ ] **Step 3: Down-sync application in handleSnapshot**

Replace the loop body of `handleSnapshot`:

```swift
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
```

Also guard the pump against tombstones (a doc may flip deleted while queued): in `pumpDownloads()` after `guard let yt = m.yt`, add:

```swift
        if meta.values.first(where: { $0.yt == yt })?.deleted == true { pumpDownloads(); return }
```

- [ ] **Step 4: Upload revives tombstones + stamps new docs**

In `upload(_:)`, replace the `if inCloud(d) { markUploaded(id); return }` fast-path with:

```swift
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
```

(`inCloud(_:)` becomes unused — delete it.) In the fresh-doc creation below, extend `doc`:

```swift
            var doc: [String: Any] = [
                "name": d.name, "folder": "", "ext": ext,
                "by": SyncDevice.id, "at": FieldValue.serverTimestamp(),
                "deleted": false,
                "metaAt": FieldValue.serverTimestamp(), "metaBy": SyncDevice.id,
            ]
            if let yt = d.videoID { doc["yt"] = yt }
            if let s = d.cropStartTime { doc["cropStartMs"] = Int(s * 1000) }
            if let e = d.cropEndTime { doc["cropEndMs"] = Int(e * 1000) }
```

(`folder` stays `""` — iOS has no folder opinion; desktop adopts its own and writes it back, which iOS then displays via `folderOverride`.)

- [ ] **Step 5: Self-verify + commit**

Trace the echo loop on paper: phone renames → `trackMetaChanged` → `pushMeta` (metaBy = self) → snapshot returns with `metaBy == SyncDevice.id` → skipped. Desktop applies it, writes nothing. Trace deletion: confirm → `trackDeleted` → `pushTombstone`; other device's snapshot → `applyDeletion` → `removeDownloadFromSync` (no `trackDeleted` fire) → no echo. Trace re-download after delete: new Download → `enqueueMissing` → `upload` → yt matches tombstone → revive.

```bash
git add musicApp/Sync/LibraryReplicator.swift musicApp/Sync/SyncSessionManager.swift musicApp/ContentView.swift
git commit -m "ios: bidirectional track metadata sync (rename/crop/folder/tombstone)"
```

---

### Task 8: Desktop replicator metadata sync + folder watch

**Files:**
- Modify: `desktop/src/replicator.ts` (imports, class state, `start`, `pump`, new `reconcile`)
- Modify: `desktop/src/ui.ts` (music-dir watcher near the `btn-library` handler, ~line 150)

**Interfaces:**
- Consumes: Task 5's `TrackMeta`; existing `norm` from `player.ts`, `DEVICE_ID`.
- Produces (used by Task 9): `Replicator.cropFor(yt?: string): { startMs?: number; endMs?: number }` and `Replicator.onCropChanged?: (yt: string) => void`.

- [ ] **Step 1: Imports and state**

In `replicator.ts` extend the firestore import with `updateDoc` and add `fs`:

```ts
import {
  Firestore, collection, doc, onSnapshot, setDoc, updateDoc, serverTimestamp, Unsubscribe,
} from "firebase/firestore";
import * as fs from "fs";
```

Add class members:

```ts
  /** Live crop change hook — ui re-applies bounds if the track is playing. */
  onCropChanged?: (yt: string) => void;

  // Last-synced name/folder per yt — the 3-way merge base that tells a disk
  // edit here apart from a cloud edit elsewhere. Persisted so offline disk
  // edits still push after a restart.
  private shadow: Record<string, { name: string; folder: string }> =
    JSON.parse(localStorage.getItem(Replicator.SHADOW_KEY) ?? "{}");
  private static readonly SHADOW_KEY = "sync.meta.shadow";
  private saveShadow() {
    localStorage.setItem(Replicator.SHADOW_KEY, JSON.stringify(this.shadow));
  }
```

and a module-level helper next to the imports:

```ts
/** Same illegal-char lens the iOS side normalizes through — applied when we
 *  WRITE filenames, so pushed-back names round-trip identically. */
const sanitize = (s: string) => s.replace(/[<>:"/\\|?*]/g, "_").trim();
```

- [ ] **Step 2: Crop lookup**

```ts
  cropFor(yt?: string): { startMs?: number; endMs?: number } {
    if (!yt) return {};
    for (const m of this.meta.values())
      if (m.yt === yt && !m.deleted)
        return { startMs: m.cropStartMs, endMs: m.cropEndMs };
    return {};
  }
```

- [ ] **Step 3: Snapshot handler respects tombstones + detects crop changes**

Replace the `start()` snapshot callback body:

```ts
      for (const ch of snap.docChanges()) {
        const m = ch.doc.data() as TrackMeta;
        if (ch.type === "removed") { this.meta.delete(ch.doc.id); continue; }
        const prev = this.meta.get(ch.doc.id);
        this.meta.set(ch.doc.id, m);
        if (m.yt && (prev?.cropStartMs !== m.cropStartMs || prev?.cropEndMs !== m.cropEndMs))
          this.onCropChanged?.(m.yt);
        // Only live, yt-bearing tracks are fetchable; tombstones also cancel
        // any queued fetch.
        if (m.yt && m.deleted) this.downQ = this.downQ.filter(q => q.yt !== m.yt);
        else if (m.yt && !this.hasLocally(m) && !this.downQ.some(q => q.yt === m.yt))
          this.downQ.push(m);
      }
      void this.pump();
```

- [ ] **Step 4: reconcile() — the 3-way merge**

Add the method and call it at the TOP of `pump()` (before the down loop, after the busy-guard sets `this.busy = true`):

```ts
  /** Metadata reconciliation, run every pump:
   *  - tombstone → delete the local file
   *  - local file gone but shadow says it was here → tombstone the doc
   *  - cloud name/folder changed → rename/move the local file
   *  - disk name/folder changed → push to the doc
   *  Cloud wins when both changed (home-scale LWW). */
  private reconcile() {
    for (const [docId, m] of this.meta) {
      if (!m.yt) continue;
      const yt = m.yt;
      const local = this.lib().find(t => t.yt === yt);
      const sh = this.shadow[yt];
      const ref = doc(this.db, "users", this.uid, "library", docId);

      if (m.deleted) {
        if (local && fs.existsSync(local.path)) {
          try { fs.unlinkSync(local.path); this.onFile(); }
          catch (e) { console.log(`[replicator] delete failed: ${m.name}`, e); }
        }
        if (sh) { delete this.shadow[yt]; this.saveShadow(); }
        continue;
      }

      if (!local) {
        // Shadow says this track lived here and the file is gone → the user
        // deleted it on disk. (First run has an empty shadow, so a library
        // that simply hasn't downloaded yet can't mass-tombstone.)
        if (sh) {
          void updateDoc(ref, {
            deleted: true, metaAt: serverTimestamp(), metaBy: DEVICE_ID,
          }).catch(() => {});
          delete this.shadow[yt]; this.saveShadow();
        }
        continue;
      }

      const localChanged = !!sh && (local.name !== sh.name || local.folder !== sh.folder);
      const cloudChanged = !sh || m.name !== sh.name || m.folder !== sh.folder;

      if (localChanged && (!cloudChanged || m.metaBy === DEVICE_ID)) {
        // Disk edit here (rename or move in the file manager) → push up.
        void updateDoc(ref, {
          name: local.name, folder: local.folder,
          metaAt: serverTimestamp(), metaBy: DEVICE_ID,
        }).catch(() => {});
        this.shadow[yt] = { name: local.name, folder: local.folder };
        this.saveShadow();
      } else if (cloudChanged) {
        // Cloud edit (or first sight) → apply down. Empty cloud folder means
        // "no opinion" (iOS-minted doc): keep the file where it is and adopt
        // the local folder into the doc — desktop is the folder authority.
        const wantName = sanitize(m.name);
        const dir = m.folder
          ? path.join(this.musicDir, sanitize(m.folder))
          : path.dirname(local.path);
        const target = path.join(dir, `${wantName} [${yt}]${path.extname(local.path)}`);
        if (target !== local.path) {
          try {
            fs.mkdirSync(dir, { recursive: true });
            fs.renameSync(local.path, target);
            this.onFile();
          } catch (e) {
            // Playing file can be locked on Windows — retried next pump.
            console.log(`[replicator] meta apply failed: ${m.name}`, e);
            continue;  // shadow untouched → retried
          }
        }
        if (!m.folder) {
          void updateDoc(ref, {
            folder: local.folder, metaAt: serverTimestamp(), metaBy: DEVICE_ID,
          }).catch(() => {});
        }
        this.shadow[yt] = { name: m.name, folder: m.folder || local.folder };
        this.saveShadow();
      }
    }
  }
```

- [ ] **Step 5: Up-loop revives tombstones and seeds the shadow**

Replace the up-loop body in `pump()`:

```ts
    // Up: local files unknown to the cloud — metadata only, no binary.
    for (const t of this.lib()) {
      if (!fs.existsSync(t.path)) continue;  // raced a reconcile deletion
      const match = [...this.meta.entries()].find(([, m]) =>
        (t.yt && m.yt === t.yt) || norm(m.name) === norm(t.name));
      const ext = path.extname(t.path).slice(1).toLowerCase();
      try {
        if (match && match[1].deleted && t.yt) {
          // Manual re-download of a deleted track → revive the doc in place.
          this.status = `Restoring “${t.name}”…`; this.onChange?.();
          await setDoc(doc(this.db, "users", this.uid, "library", match[0]), {
            name: t.name, folder: t.folder, ext, yt: t.yt, by: DEVICE_ID,
            deleted: false, at: serverTimestamp(),
            metaAt: serverTimestamp(), metaBy: DEVICE_ID,
          });
          this.shadow[t.yt] = { name: t.name, folder: t.folder };
          this.saveShadow();
          continue;
        }
        if (match) {
          if (t.yt && !this.shadow[t.yt]) {
            this.shadow[t.yt] = { name: match[1].name, folder: match[1].folder || t.folder };
            this.saveShadow();
          }
          continue;
        }
        this.status = `Mirroring “${t.name}”…`; this.onChange?.();
        const m: TrackMeta = { name: t.name, folder: t.folder, ext, by: DEVICE_ID };
        if (t.yt) m.yt = t.yt;
        await setDoc(doc(this.db, "users", this.uid, "library", t.id), {
          ...m, at: serverTimestamp(),
          deleted: false, metaAt: serverTimestamp(), metaBy: DEVICE_ID,
        });
        this.meta.set(t.id, m);
        if (t.yt) { this.shadow[t.yt] = { name: t.name, folder: t.folder }; this.saveShadow(); }
      } catch (e) { console.log(`[replicator] up failed: ${t.name}`, e); }
    }
```

Call `this.reconcile();` as the first statement after `this.busy = true;` in `pump()`.

- [ ] **Step 6: Watch the music dir so disk edits sync within seconds**

In `ui.ts`, add near the other module-level state:

```ts
let watchTimer: ReturnType<typeof setTimeout> | null = null;
function watchMusicDir(dir: string) {
  try {
    fs.watch(dir, { recursive: true }, () => {
      if (watchTimer) clearTimeout(watchTimer);
      watchTimer = setTimeout(() => {
        engine.loadLibrary(dir);
        renderLibrary();
        replicator.syncUp();  // pump → reconcile pushes renames/moves/deletes
      }, 2000);
    });
  } catch { /* fs.watch unavailable — edits sync on next launch/download */ }
}
```

(`import * as fs from "fs";` at the top of `ui.ts` if not already imported.) Call `watchMusicDir(dir)` in BOTH places `musicDir` becomes live: the startup path that reads `DIR_KEY` and calls `engine.loadLibrary(musicDir)`, and the `btn-library` picker handler after `engine.loadLibrary(dir)`.

- [ ] **Step 7: Verify + commit**

`cd desktop && npm run build` — exit 0.

```bash
git add desktop/src/replicator.ts desktop/src/ui.ts
git commit -m "desktop: bidirectional track metadata sync with revivable tombstones + dir watch"
```

---

### Task 9: Desktop crop-aware playback + lyrics compensation

**Files:**
- Modify: `desktop/src/player.ts` (`LocalPlayer`)
- Modify: `desktop/src/engine.ts` (`playLocal`, `trackEnded`, `takeOverHere`, new `cropLookup`)
- Modify: `desktop/src/ui.ts` (wiring + lyrics highlight/click, ~lines 588-616)

**Interfaces:**
- Consumes: Task 8's `replicator.cropFor` / `onCropChanged`.
- Produces: `LocalPlayer.setCrop(startMs?, endMs?)`; `SyncEngine.cropLookup: (yt?: string) => { startMs?: number; endMs?: number }`; `SyncEngine.refreshCurrentCrop()`. All positions/durations exposed by `LocalPlayer` become crop-relative — matching iOS, whose published `pos`/`dur` are already crop-relative (`protocol.ts:17`).

- [ ] **Step 1: Crop bounds in LocalPlayer**

Add fields + method to `LocalPlayer`:

```ts
  // Crop window (metadata — the file is untouched). All public positions are
  // crop-relative: 0 == cropStart, durMs == cropEnd - cropStart. This matches
  // what iOS publishes for cropped tracks (protocol dur = "cropped length").
  private cropStartMs = 0;
  private cropEndMs?: number;
  private endFired = false;

  setCrop(startMs?: number, endMs?: number) {
    this.cropStartMs = startMs ?? 0;
    this.cropEndMs = endMs;
    this.endFired = false;
  }
```

In the constructor add end-of-crop detection:

```ts
    this.el.addEventListener("timeupdate", () => {
      if (this.cropEndMs !== undefined && this.current && !this.endFired
          && this.el.currentTime * 1000 >= this.cropEndMs) {
        this.endFired = true;
        this.onEnded?.();
      }
    });
```

Make the getters/mutators crop-relative:

```ts
  get posMs() { return Math.max(0, this.el.currentTime * 1000 - this.cropStartMs); }
  get durMs() {
    const raw = Number.isFinite(this.el.duration) ? this.el.duration * 1000 : 0;
    if (!raw) return 0;
    return Math.max(0, Math.min(this.cropEndMs ?? raw, raw) - this.cropStartMs);
  }
```

In `play(t, atMs, startPaused)` change the seek line to `this.el.currentTime = (atMs + this.cropStartMs) / 1000;` and add `this.endFired = false;` before it. In `seekMs(ms)`: `this.el.currentTime = (ms + this.cropStartMs) / 1000; this.endFired = false; this.onChange?.();`.

- [ ] **Step 2: Engine applies crops at every entry point**

Add to `SyncEngine`:

```ts
  /** Wired by ui.ts to the replicator's cloud metadata. */
  cropLookup: (yt?: string) => { startMs?: number; endMs?: number } = () => ({});

  private applyCrop(t: LocalTrack) {
    const c = this.cropLookup(t.yt);
    this.player.setCrop(c.startMs, c.endMs);
  }

  /** Crop metadata changed for the loaded track (e.g. cropped on the phone
   *  while playing here) — re-apply; timeupdate handles an already-passed end. */
  refreshCurrentCrop() {
    if (this.player.current) this.applyCrop(this.player.current);
  }
```

Insert `this.applyCrop(local);` / `this.applyCrop(t);` immediately BEFORE each `this.player.play(...)` call: in `trackEnded` (before `this.player.play(local)`), in `playLocal` (before `this.player.play(t)`), and in `takeOverHere` (before `this.player.play(local, posMs, ...)` — the handover position is already crop-relative because the old owner published crop-relative positions).

- [ ] **Step 3: Wire it in ui.ts**

After both `engine` and `replicator` are constructed:

```ts
engine.cropLookup = yt => replicator.cropFor(yt);
replicator.onCropChanged = yt => {
  if (engine.player.current?.yt === yt) engine.refreshCurrentCrop();
};
```

- [ ] **Step 4: Lyrics compensate for crops automatically**

In `ui.ts` add:

```ts
/** LRC timestamps are full-file-relative; session positions are crop-relative.
 *  The crop offset is now known from library metadata — no manual nudge needed. */
function lyricsCropStartMs(): number {
  const ref = coord.remote?.playback.track;
  return (ref?.yt ? replicator.cropFor(ref.yt).startMs : undefined) ?? 0;
}
```

In `updateLyricsHighlight()` change the index line to:

```ts
  const idx = activeIndex(lyricsLines, currentPosMs() + lyricsCropStartMs(), lyricsOffsetMs) ?? -1;
```

In `renderLyrics()` change the line-click seek to:

```ts
    d.onclick = () => seekCmd(Math.max(0, line.timeMs + lyricsOffsetMs - lyricsCropStartMs()));
```

Update the stale comment block above `updateLyricsHighlight` (~lines 598-601): replace the "lines run early by cropStart, and the shared offsetMs nudge is the manual fix" sentence with "cropped tracks are compensated via the library doc's cropStartMs; offsetMs remains a pure alignment nudge."

- [ ] **Step 5: Verify + commit**

`cd desktop && npm run build` — exit 0. Trace on paper: iOS plays a cropped track (publishes crop-relative pos) → desktop mirror shows correct progress against `pb.dur` (unchanged) → desktop "Play Here" seeks to `posMs + cropStartMs` absolute via `play()` ✓; desktop-owned playback of a cropped track ends at `cropEndMs` and advances ✓.

```bash
git add desktop/src/player.ts desktop/src/engine.ts desktop/src/ui.ts
git commit -m "desktop: crop-aware playback + automatic lyric crop compensation"
```

---

### Task 10: Lyric offset freshness (both platforms)

**Files:**
- Modify: `musicApp/Lyrics/LyricsService.swift` (`resolve` ~line 73, new method)
- Modify: `desktop/src/lyrics.ts` (`LyricsStore.get` ~line 224, new method)
- Modify: `desktop/src/ui.ts` (wire `onOffset`, near the other `lyricsStore` setup)

**Interfaces:**
- Consumes: existing `lyricsRef(_:)` (iOS, used by `nudgeOffset`), `this.ref(uid, key)` (desktop).
- Produces: `LyricsStore.onOffset?: (trackKey: string, offsetMs: number) => void`.

- [ ] **Step 1: iOS — re-read offset when serving a cached doc**

In `resolve(track:download:requested:force:)`, only the memory/disk-cache hit path (~line 75) needs the refresh — the Firestore-hit path just read the cloud. Change it to:

```swift
            if let doc = memory[track.id] ?? Self.readDisk(track.id) {
                memory[track.id] = doc
                if !(doc.notFound && Self.expired(doc)) {
                    apply(doc, for: requested)
                    await refreshCloudOffset(track.id, requested: requested)
                    return
                }
            }
```

Add:

```swift
    /// A disk/memory-cached doc skips the Firestore read, so a nudge made on
    /// another device never lands here — re-read JUST the offset and prefer
    /// the cloud value. Best-effort: offline keeps the cached offset.
    private func refreshCloudOffset(_ id: UUID, requested: UUID) async {
        guard let ref = lyricsRef(id),
              let snap = try? await ref.getDocument(),
              let cloudOffset = snap.data()?["offsetMs"] as? Int,
              var doc = memory[id], doc.offsetMs != cloudOffset else { return }
        doc.offsetMs = cloudOffset
        memory[id] = doc
        Self.writeDisk(id, doc)
        if requested == trackID, case .synced(let lines, _) = state {
            state = .synced(lines: lines, offsetMs: cloudOffset)
        }
    }
```

- [ ] **Step 2: Desktop — same fix on the memory-cache path**

In `LyricsStore`:

```ts
  /** Fired when a background offset refresh finds a newer cloud value. */
  onOffset?: (trackKey: string, offsetMs: number) => void;

  private async refreshOffset(uid: string, key: string): Promise<void> {
    if (!uid) return;
    const snap = await getDoc(this.ref(uid, key)).catch(() => null);
    if (!snap?.exists()) return;
    const off = (snap.data() as { offsetMs?: number }).offsetMs;
    if (off === undefined) return;
    const cached = this.memory.get(key);
    if (!cached || cached.offsetMs === off) return;
    cached.offsetMs = off;
    this.onOffset?.(key, off);
  }
```

and in `get(...)` change the memory-hit return:

```ts
    const cached = this.memory.get(key);
    if (cached && !this.expiredNotFound(cached)) {
      // Cached docs skip Firestore — refresh just the nudge offset in the
      // background so a phone-side alignment fix lands mid-session.
      void this.refreshOffset(uid, key);
      return cached;
    }
```

- [ ] **Step 3: ui.ts applies live offset updates**

Near the other initialization (where `lyricsStore` handlers/bindings are set up):

```ts
lyricsStore.onOffset = (key, off) => {
  if (lyricsTrackId && key === lyricsTrackId.toUpperCase()) {
    lyricsOffsetMs = off;
    $("lyr-off").textContent =
      `${lyricsOffsetMs >= 0 ? "+" : ""}${(lyricsOffsetMs / 1000).toFixed(1)}s`;
    lyricsActiveIdx = -1;
    updateLyricsHighlight();
  }
};
```

- [ ] **Step 4: Verify + commit**

`cd desktop && npm run build` — exit 0.

```bash
git add musicApp/Lyrics/LyricsService.swift desktop/src/lyrics.ts desktop/src/ui.ts
git commit -m "lyrics: refresh nudge offset from the cloud when serving cached docs"
```

---

## Final verification

- Desktop: `cd desktop && npm run build` exits 0.
- Swift: no build available here — walk the spec's manual test matrix (items 1–13) on a real device pair and report results honestly.
- Re-read the spec (`docs/superpowers/specs/2026-07-13-ios-remote-playback-control-design.md`) section by section and confirm each maps to a completed task: Part 1 → Tasks 1–3, Part 2 → Task 4, Part 3 → Tasks 5–8, Part 4 → Task 10, desktop crop playback → Task 9.
