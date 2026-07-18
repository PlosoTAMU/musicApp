import Foundation
import Combine
import FirebaseFirestore

/// Reconciliation between the local AudioPlayerManager and the remote session doc.
///
/// Owner direction (local → remote): observes the player via Combine, publishes
/// state ONLY on discrete transitions — play, pause, seek, track change, rate
/// change — plus a 30 s anchor refresh while playing. Position is never streamed;
/// followers extrapolate from `(positionMs, anchorMs, rate)`.
///
/// Follower direction (remote → local): mirrors playback for UI, applies queue
/// edits into the local player. No audio until the user takes over.
///
/// Loop-breaking (the actual hard part):
///  - `updatedBy` filtering in the coordinator kills same-device echo.
///  - Remote queue applies record `lastAppliedQueueIDs`; the debounced local
///    queue observer skips publishes matching it (a plain `applyingRemote` bool
///    fails here — the debounce fires after the flag resets).
///  - Ghost suppression: remote tracks this device can't resolve to a file must
///    not be deleted for everyone just because our library lacks them.
@MainActor
final class PlaybackSyncEngine: ObservableObject {

    let coordinator: SessionCoordinator
    private let player: AudioPlayerManager
    private let resolver: TrackResolving
    private let queueSync: QueueSync
    private let commands: CommandBus

    // Follower-side mirror for UI. Position is computed on demand from this
    // rather than republished on a timer — a consumer can tick its own display
    // (e.g. a TimelineView) only while visible.
    @Published private(set) var mirror: PlaybackState?
    /// Remote queue entries with no matching local file (UI can offer download).
    @Published private(set) var ghostQueue: [TrackRef] = []
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

    /// Stricter than isRemoteControlled: the owner is ANOTHER device and its
    /// lease is fresh — commands sent now will actually be executed. This is
    /// the gate for routing local play taps to the owner; a dead owner means
    /// commands go nowhere, so playback falls back to "play here" (takeover).
    var hasLiveRemoteOwner: Bool {
        guard coordinator.role == .follower,
              let s = coordinator.remote,
              !s.ownerDeviceID.isEmpty,
              s.ownerDeviceID != SyncDevice.id,
              !s.leaseExpired else { return false }
        return true
    }

    /// Remote-mode play routing (wired into AudioPlayerManager.playRouter):
    /// while another device owns playback, a local tap becomes a `playTrack`
    /// command over there — this device stays silent. Returns true when routed.
    func routePlayIfRemote(_ track: Track) -> Bool {
        guard hasLiveRemoteOwner else { return false }
        let ref = TrackRef(track: track)
        commands.send(.playTrack(ref))
        // Optimistic mirror — the command round-trips 0.7–2 s; show the chosen
        // track now. The owner's settle publish replaces the whole mirror.
        let now = ServerClock.shared.nowMs
        mirror = PlaybackState(track: ref, isPlaying: true, positionMs: 0,
                               anchorMs: now,
                               rateX1000: mirror?.rateX1000 ?? 1000,
                               durationMs: 0, rev: mirror?.rev ?? 0)
        mirrorTrack = track
        return true
    }

    private var bag = Set<AnyCancellable>()
    private var isApplyingRemotePlaybackCommand = false
    private let publishTrigger = PassthroughSubject<Void, Never>()

    // Seek detection state.
    private var lastTimeSample: Double?
    private var lastTimeLocalMs: Double?

    // Echo suppression.
    private var lastAppliedQueueIDs: [UUID]?
    private var suppressConsumePublish = false

    private var anchorTimer: Timer?

    init(player: AudioPlayerManager, coordinator: SessionCoordinator,
         resolver: TrackResolving) {
        self.player = player
        self.coordinator = coordinator
        self.resolver = resolver
        self.queueSync = QueueSync(
            db: coordinator.db,
            sessionRef: { [weak coordinator] in coordinator?.sessionRef },
            isOnline: coordinator.$isOnline.eraseToAnyPublisher()
        )
        self.commands = CommandBus(
            db: coordinator.db,
            sessionRef: { [weak coordinator] in coordinator?.sessionRef }
        )
        wireCoordinator()
        wirePlayerObservation()
        wireTimers()
    }

    // MARK: - Coordinator hooks

    private func wireCoordinator() {
        coordinator.onDeposed = { [weak self] in
            // Another device took over. Audio must transfer, not double-play.
            self?.player.pause()
            self?.commands.stopListening()
        }
        coordinator.onSessionState = { [weak self] state, isEcho in
            self?.handleRemote(state, isEcho: isEcho)
        }
        coordinator.$role
            .removeDuplicates()
            .sink { [weak self] role in
                guard let self else { return }
                if role.isOwner {
                    self.commands.startListening { [weak self] cmd in
                        Task { @MainActor in self?.applyCommand(cmd) }
                    }
                } else {
                    self.commands.stopListening()
                    // Attach lands us in .follower — if local audio is ALREADY
                    // playing (user played before connecting), the isPlaying
                    // observer never fires (no transition), so claim here.
                    if role == .follower { self.reconcileLocalPlayback() }
                }
            }
            .store(in: &bag)

        // Reconnect reconciliation: a claim that failed offline (or playback
        // started while offline) must retry the moment we're back — otherwise
        // this device plays audio the session doesn't know about, and a stale
        // remote owner can double-play against us.
        coordinator.$isOnline
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.reconcileLocalPlayback() }
            .store(in: &bag)
    }

    /// Local audio playing while not owner ⇒ the session must be claimed.
    /// Covers: play-before-connect, claim txn lost offline, reconnect races.
    private func reconcileLocalPlayback() {
        guard player.isPlaying, !coordinator.role.isOwner,
              coordinator.role != .none else { return }
        claimSessionForLocalPlayback()
    }

    // Ask the current owner to re-publish once per distinct owner we observe.
    // Covers the join-mid-playback case: our first snapshot may be a cached or
    // long-stale frame, so we pull a fresh authoritative state (new anchor)
    // instead of trusting whatever the doc held when we attached.
    private var syncedOwner: String?

    private func handleRemote(_ state: SessionState, isEcho: Bool) {
        // Display + join-resync run on EVERY snapshot, echoes included — the
        // first frame after a relaunch is usually our own last write, and it
        // must still populate the mirror and trigger the owner ping.
        mirror = state.playback
        mirrorTrack = state.playback.track.flatMap { resolver.resolve($0) }

        let owner = state.ownerDeviceID
        if !owner.isEmpty, owner != SyncDevice.id, owner != syncedOwner {
            syncedOwner = owner
            commands.send(.requestStatus)
        }

        // Queue application is loop-sensitive: replaying our own write echo
        // could clobber a newer local edit — echoes stop here.
        guard !isEcho else { return }

        // Queue: resolve remote refs to local tracks; track ghosts separately.
        let resolvedPairs = state.queue.map { ($0, resolver.resolve($0)) }
        ghostQueue = resolvedPairs.filter { $0.1 == nil }.map(\.0)
        let resolved = resolvedPairs.compactMap(\.1)
        let resolvedIDs = resolved.map(\.id)

        if player.queue.map(\.id) != resolvedIDs {
            lastAppliedQueueIDs = resolvedIDs
            player.queue = resolved
        }
    }

    private func applyCommand(_ cmd: SyncCommand) {
        // Resync ping — answer with our authoritative state, no transport change.
        if case .requestStatus = cmd { publishNow(); return }

        isApplyingRemotePlaybackCommand = true
        defer { isApplyingRemotePlaybackCommand = false }

        switch cmd {
        case .play: player.resume()
        case .pause: player.pause()
        case .next: player.next()
        case .previous: player.previous()
        case .seek(let ms): player.seek(to: Double(ms) / 1000.0)
        case .playTrack(let ref):
            // Remote device tapped a song — play it HERE (we own the audio).
            // Unresolvable (not in this library) plays nothing; the settle
            // publish below re-asserts our truth and corrects the sender's
            // optimistic mirror.
            if let track = resolver.resolve(ref) { player.play(track) }
        case .requestStatus: break   // handled above
        }
        // Direct publish removes the observer's 200 ms debounce from the remote
        // command round trip. Transport mutations land via audioQueue → main
        // hops, so the publish rides the same path — a synchronous publishNow()
        // here would snapshot pre-command state. The debounced observer publish
        // still fires afterwards; the duplicate is harmless (rev is monotonic).
        player.afterTransportSettles { [weak self] in
            Task { @MainActor in self?.publishNow() }
        }
    }

    // MARK: - Local player observation (owner publish pipeline)

    private func wirePlayerObservation() {
        // Discrete transitions → coalesced publish. 200 ms debounce merges
        // compound events (track change flips isPlaying + currentTrack + time).
        publishTrigger
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.publishNow() }
            .store(in: &bag)

        player.$isPlaying
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self else { return }
                self.resetSeekDetection()
                // Implicit takeover: the iOS UI plays audio by calling the
                // player directly (this engine only observes), and a follower
                // never has local audio unless the user just started a song
                // HERE — the remote mirror is display-only. So isPlaying → true
                // while not owner means "play here": claim the session so this
                // playback publishes. Twin of desktop engine.playLocal()'s
                // takeOver(). Owner pause/resume falls through to publishTrigger.
                if playing && !self.coordinator.role.isOwner {
                    self.claimSessionForLocalPlayback()
                } else {
                    self.publishTrigger.send()
                }
            }
            .store(in: &bag)

        player.$currentTrack
            .dropFirst()
            .removeDuplicates(by: { $0?.id == $1?.id })
            .sink { [weak self] newTrack in
                self?.handleLocalTrackChange(newTrack)
            }
            .store(in: &bag)

        // Rate changes alter follower extrapolation — must re-anchor.
        player.$playbackSpeed
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.publishTrigger.send() }
            .store(in: &bag)
        player.$effectsBypass
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.publishTrigger.send() }
            .store(in: &bag)

        // Seek detection: player ticks currentTime every 0.5 s. Predict the next
        // sample from wall time × rate; a jump beyond 1.5 s means a discontinuity
        // (user scrub, remote-command seek, crop skip) → re-anchor.
        player.$currentTime
            .sink { [weak self] t in
                guard let self, self.coordinator.role.isOwner else { return }
                let nowLocal = ServerClock.localNowMs
                defer { self.lastTimeSample = t; self.lastTimeLocalMs = nowLocal }
                guard self.player.isPlaying,
                      let lastT = self.lastTimeSample,
                      let lastLocal = self.lastTimeLocalMs else { return }
                let expected = lastT + (nowLocal - lastLocal) / 1000.0 * self.player.effectivePlaybackSpeed
                if abs(t - expected) > 1.5 { self.publishTrigger.send() }
            }
            .store(in: &bag)

        // Queue edits (any role — queue is shared, unlike playback).
        player.$queue
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] q in self?.handleLocalQueueChange(q) }
            .store(in: &bag)
    }

    private func handleLocalTrackChange(_ newTrack: Track?) {
        resetSeekDetection()

        guard coordinator.role.isOwner else { return }
        // next() consumed the queue head → CAS pop instead of bulk overwrite,
        // so a follower's concurrent insert survives.
        if let remoteHead = coordinator.remote?.queue.first,
           let newTrack, resolver.resolve(remoteHead)?.id == newTrack.id {
            suppressConsumePublish = true
            let basis = coordinator.remote?.queueVersion ?? 0
            Task { await queueSync.apply(.consumeHead(expected: remoteHead.id), basisVersion: basis) }
        }
        publishTrigger.send()
    }

    private func handleLocalQueueChange(_ queue: [Track]) {
        guard coordinator.role != .none else { return }
        let localIDs = queue.map(\.id)

        // Echo of a remote apply — not user intent.
        if localIDs == lastAppliedQueueIDs { return }
        // Echo of consumeHead's local mutation.
        if suppressConsumePublish {
            suppressConsumePublish = false
            return
        }
        // Ghost suppression: if local == remote minus unresolvable tracks, the
        // delta is missing files, not intent. Publishing would delete those
        // tracks from every other device's queue.
        if let remote = coordinator.remote?.queue {
            let resolvableRemoteIDs = remote.compactMap { resolver.resolve($0)?.id }
            if localIDs == resolvableRemoteIDs { return }
        }

        // Genuine local edit → LWW bulk publish, ghosts preserved in place.
        let refs = mergeGhosts(local: queue.map(TrackRef.init), ghosts: ghostQueue,
                               remoteOrder: coordinator.remote?.queue ?? [])
        let basis = coordinator.remote?.queueVersion ?? 0
        Task { await queueSync.apply(.replaceAll(refs), basisVersion: basis) }
    }

    /// Re-inserts ghost refs at their remote positions (anchored by predecessor id)
    /// so a local edit doesn't silently drop tracks we merely can't play.
    private func mergeGhosts(local: [TrackRef], ghosts: [TrackRef],
                             remoteOrder: [TrackRef]) -> [TrackRef] {
        guard !ghosts.isEmpty else { return local }
        var out = local
        for ghost in ghosts {
            guard let remoteIdx = remoteOrder.firstIndex(where: { $0.id == ghost.id }) else {
                out.append(ghost); continue
            }
            // Anchor: nearest preceding remote entry that still exists locally.
            let predecessor = remoteOrder[..<remoteIdx].last(where: { r in out.contains(where: { $0.id == r.id }) })
            if let pred = predecessor, let i = out.firstIndex(where: { $0.id == pred.id }) {
                out.insert(ghost, at: i + 1)
            } else {
                out.insert(ghost, at: 0)
            }
        }
        return out
    }

    private func resetSeekDetection() {
        lastTimeSample = nil
        lastTimeLocalMs = nil
    }

    // MARK: - Publish

    private func snapshotState() -> PlaybackState {
        PlaybackState(
            track: player.currentTrack.map(TrackRef.init),
            isPlaying: player.isPlaying,
            // liveCurrentTime, not currentTime: the cached value is refreshed
            // on a 0.5 s timer, and a position up to 500 ms stale paired with
            // a fresh anchorMs skews every follower's extrapolation.
            positionMs: Int(player.liveCurrentTime() * 1000),
            anchorMs: ServerClock.shared.nowMs,
            rateX1000: Int(player.effectivePlaybackSpeed * 1000),
            durationMs: Int(player.duration * 1000),
            rev: 0   // assigned inside the fenced transaction
        )
    }


    

    private func publishNow() {
        guard coordinator.role.isOwner else { return }
        let state = snapshotState()
        Task { await coordinator.publishPlayback(state) }
    }

    // MARK: - Timers

    private func wireTimers() {
        // Anchor refresh: bounds follower extrapolation drift (clock skew, DSP
        // rate imprecision from time-pitch effects) to ≤30 s of accumulation.
        anchorTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.coordinator.role.isOwner, self.player.isPlaying else { return }
                self.publishNow()
            }
        }
    }


    // In-flight guard: reconcile can fire from several triggers (role flip,
    // reconnect, isPlaying) — one takeover txn at a time.
    private var claimInFlight = false

    private func claimSessionForLocalPlayback() {
        guard !claimInFlight else { return }
        claimInFlight = true
        Task { @MainActor in
            defer { claimInFlight = false }
            do {
                _ = try await coordinator.takeOver()
                publishNow()
            } catch {
                print("[PlaybackSyncEngine] local playback takeover failed:", error)
                publishTrigger.send()
            }
        }
    }



    // MARK: - Handover (the takeover path)

    /// "Play here": fenced epoch bump, then resume audio at the extrapolated
    /// position of the OLD owner — continuity is computed from the pre-takeover
    /// state returned by the transaction, not from a racy follow-up read.
    ///
    /// `forcePlay` is the Bluetooth-handoff path: the old owner paused the
    /// moment its headphones dropped, so the session reads "paused" — but the
    /// user's intent is continuation, not a paused handover.
    func takeOverHere(forcePlay: Bool = false) async throws {
        let pre = try await coordinator.takeOver()
        let pb = pre.playback
        let posMs = pb.positionMs(atServerMs: ServerClock.shared.nowMs)

        if let ref = pb.track, let track = resolver.resolve(ref) {
            let resolvedQueue = pre.queue.compactMap(resolver.resolve)
            lastAppliedQueueIDs = resolvedQueue.map(\.id)
            player.queue = resolvedQueue
            // Audio starts exactly at the old owner's extrapolated position;
            // paused handovers arm resume() without scheduling audio.
            player.play(track, at: Double(posMs) / 1000.0,
                        startPaused: !(pb.isPlaying || forcePlay))
        }
        // New epoch, rev 0 — publish our authoritative state immediately.
        publishNow()
    }

    // MARK: - Follower controls (route through the command bus)

    func requestPlay()      { route(.play) }
    func requestPause()     { route(.pause) }
    func requestNext()      { route(.next) }
    func requestPrevious()  { route(.previous) }
    func requestSeek(ms: Int) { route(.seek(ms: ms)) }

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
        // No live owner ⇒ no authoritative snapshot will ever correct the
        // patch — an optimistic lie would stick forever. Skip it.
        guard !(coordinator.remote?.leaseExpired ?? true) else { return }
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
        case .next, .previous, .playTrack:
            return  // target track unknown until the owner's snapshot arrives
        case .requestStatus:
            return  // not a transport command — never routed through here
        }
        mirror = pb
    }
}
