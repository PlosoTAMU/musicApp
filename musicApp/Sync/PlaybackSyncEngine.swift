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
    /// A NON-empty ownerDeviceID that equals SELF is a zombie from a prior
    /// crash/kill; SessionCoordinator *releases* it on the first fresh
    /// snapshot, but until that lands (or if the release write fails) the UI
    /// must not treat SELF as "the remote" (sync-audit-3.md F1).
    var isRemoteControlled: Bool {
        guard coordinator.role == .follower,
              let owner = coordinator.remote?.ownerDeviceID,
              !owner.isEmpty else { return false }
        return owner != SyncDevice.id
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

    /// Remote display mode is on, but the owner's lease has lapsed — it is not
    /// draining commands, so the transport here is inert until someone takes
    /// over. Twin of desktop ui.ts's `#owner-dead` chip / dead-owner banner.
    /// SessionCoordinator's F3 clear usually retires this within one snapshot;
    /// the affordance covers the window (and the offline case, where F3 is
    /// deliberately skipped).
    var remoteOwnerIsDead: Bool { isRemoteControlled && !hasLiveRemoteOwner }

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
    /// After a track-change fires our own `consumeHead`, the debounced queue
    /// observer is expected to see the queue MINUS the popped head — snapshot
    /// that state and, when the observer fires, skip publishing only if the
    /// observed queue matches exactly. Any delta = the user also edited during
    /// the debounce window; publish it (sync-audit-3.md F11 — the prior flag
    /// silently ate that user intent). The same slot absorbs the queue-intent
    /// path (sync-audit-4 M11): whenever a rebasable op has already been sent
    /// for a mutation, the observer must not also LWW-overwrite the result.
    private var expectedQueueAfterConsume: [UUID]?

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
        wireQueueIntents()
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

        // A live owner is answering again — retire the dead-owner prompt.
        if lastCommandHitDeadOwner, hasLiveRemoteOwner {
            lastCommandHitDeadOwner = false
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
        case .setLoop(let on): player.isLoopEnabled = on
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

    // MARK: - Queue intents (rebasable ops instead of LWW overwrites)

    /// Every iOS queue change used to reach the cloud as `replaceAll` — the
    /// whole array, Last-Writer-Wins — so a desktop insert that landed inside
    /// the 300 ms debounce window was silently erased, while desktop had used
    /// rebasable intent ops all along (sync-audit-4 M11).
    ///
    /// AudioPlayerManager now reports what the user actually did; this turns it
    /// into the matching QueueOp, which the transaction rebases against the
    /// live queue by trackID. The debounced observer stays as the fallback for
    /// anything not described here (multi-row drags, direct queue assignment).
    private func wireQueueIntents() {
        player.onQueueIntent = { [weak self] intent in
            self?.publishQueueIntent(intent)
        }
    }

    private func publishQueueIntent(_ intent: QueueIntent) {
        guard coordinator.role != .none else { return }

        let op: QueueOp?
        switch intent {
        case .append(let tracks):
            op = tracks.isEmpty ? nil : .append(tracks.map(TrackRef.init))
        case .injectFront(let tracks, let removing):
            op = .injectFront(refs: tracks.map(TrackRef.init), removeIDs: removing)
        case .remove(let ids):
            op = ids.isEmpty ? nil : .removeMany(ids)
        case .move(let id, let afterID):
            op = .move(id, afterID: afterID)
        case .clear:
            // Genuinely a bulk overwrite — replaceAll is the right op, and
            // "clear" is unambiguous intent, not a stale snapshot.
            op = .replaceAll([])
        }
        guard let op else { return }

        // Suppress the debounced observer for exactly this result: it would
        // otherwise follow up with an LWW replaceAll and undo the merge the
        // rebase just achieved. Any OTHER queue shape means the user edited
        // again during the window, and that publishes normally.
        expectedQueueAfterConsume = player.queue.map(\.id)
        let basis = coordinator.remote?.queueVersion ?? 0
        Task { await queueSync.apply(op, basisVersion: basis) }
    }

    private func handleLocalTrackChange(_ newTrack: Track?) {
        resetSeekDetection()

        guard coordinator.role.isOwner else { return }
        // next() consumed the queue head → CAS pop instead of bulk overwrite,
        // so a follower's concurrent insert survives.
        if let newTrack, let run = consumedHeadRun(endingAt: newTrack) {
            // player.queue was already mutated (head removed) by
            // AudioPlayerManager.next(). If the debounced observer sees this
            // exact same set of ids later, it's the natural consume-echo and
            // we skip republishing. If it sees something different, the user
            // edited during the debounce window — publish that intent.
            expectedQueueAfterConsume = player.queue.map(\.id)
            let basis = coordinator.remote?.queueVersion ?? 0
            Task { await queueSync.apply(.consumeHeadRun(expected: run), basisVersion: basis) }
        }
        publishTrigger.send()
    }

    /// The shared-queue entries this advance consumed: every leading entry this
    /// device can't resolve (handleRemote filters them out of `player.queue`,
    /// so `next()` never saw them) followed by the track that actually started.
    ///
    /// nil when the first resolvable entry ISN'T the new track — then the track
    /// change wasn't a queue advance at all (a library tap, say) and the shared
    /// queue must not be touched.
    ///
    /// Before this, the CAS compared only against `queue.first`, so a single
    /// unplayable track at the head made every advance's CAS miss forever and
    /// mergeGhosts re-pinned it at index 0 on the next publish — the queue could
    /// never drain past it (sync-audit-4 B5). Twin of desktop trackEnded's walk
    /// over `coord.remote.queue`.
    private func consumedHeadRun(endingAt newTrack: Track) -> [UUID]? {
        guard let remoteQ = coordinator.remote?.queue else { return nil }
        var run: [UUID] = []
        for ref in remoteQ {
            guard let t = resolver.resolve(ref) else {
                run.append(ref.id)          // ghost — invisible to the player
                continue
            }
            guard t.id == newTrack.id else { return nil }
            run.append(ref.id)
            return run
        }
        return nil                          // queue is all ghosts — not an advance
    }

    private func handleLocalQueueChange(_ queue: [Track]) {
        guard coordinator.role != .none else { return }
        let localIDs = queue.map(\.id)

        // Echo of a remote apply — not user intent.
        if localIDs == lastAppliedQueueIDs { return }
        // Echo of our own consumeHead — but ONLY if the queue looks EXACTLY
        // like what we snapshotted right after that consume. Any delta = user
        // intent to publish (sync-audit-3.md F11).
        if let expected = expectedQueueAfterConsume {
            expectedQueueAfterConsume = nil
            if localIDs == expected { return }
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
    ///
    /// Executable spec + cases: `desktop/tests/syncAudit-ghostmerge.test.ts`.
    /// Twin of PlaylistSync.mergedTracks — keep the three in step.
    ///
    /// `placed` is load-bearing: a RUN of consecutive ghosts sharing one anchor
    /// must keep remote order. Inserting each at `anchor + 1` pushes the
    /// previous one right and reverses the run — so two unplayable tracks
    /// sitting next to each other in the shared queue swapped places on every
    /// local queue edit (sync-audit-4 B7). Each sibling is offset past the ones
    /// already placed for that anchor; `base` is recomputed every iteration
    /// because inserts for earlier anchors shift the anchor's index.
    private func mergeGhosts(local: [TrackRef], ghosts: [TrackRef],
                             remoteOrder: [TrackRef]) -> [TrackRef] {
        guard !ghosts.isEmpty else { return local }
        var out = local
        let frontKey = UUID()   // sentinel: ghosts with no surviving predecessor
        var placed: [UUID: Int] = [:]

        // Remote order, not `ghosts` order, so sibling runs stay stable.
        let ghostIDs = Set(ghosts.map(\.id))
        for (idx, ghost) in remoteOrder.enumerated() where ghostIDs.contains(ghost.id) {
            let anchor = remoteOrder[..<idx]
                .last { r in out.contains { $0.id == r.id } }
            let key = anchor?.id ?? frontKey
            let offset = placed[key] ?? 0
            let base = anchor.flatMap { a in
                out.firstIndex { $0.id == a.id }.map { $0 + 1 }
            } ?? 0
            out.insert(ghost, at: base + offset)
            placed[key] = offset + 1
        }
        // A ghost the remote list no longer carries (raced deletion) — keep it
        // rather than dropping a track we simply can't see.
        for ghost in ghosts where !remoteOrder.contains(where: { $0.id == ghost.id }) {
            out.append(ghost)
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
            rev: 0,  // assigned inside the fenced transaction
            loop: player.isLoopEnabled
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
    ///
    /// Refuses BEFORE the epoch bump if the session's track can't resolve here.
    /// The takeover deposes the real owner, so going ahead and then failing to
    /// resolve stopped the music on every device and published `track: nil` —
    /// reachable from RouteHandoffMonitor, which calls this with no UI guard
    /// when headphones hop to a phone that lacks the song (sync-audit-4 B4).
    /// Twin of desktop engine.ts's takeOverHere pre-check.
    func takeOverHere(forcePlay: Bool = false) async throws {
        if let ref = coordinator.remote?.playback.track, resolver.resolve(ref) == nil {
            throw SyncError.trackNotHere(ref.name)
        }
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
    func setLoop(_ on: Bool) { route(.setLoop(on)) }

    /// Non-idempotent commands (next/prev) get a short client-side rate-limit
    /// so a rapid double-tap on the follower doesn't skip TWO tracks
    /// (sync-audit-3.md F12). Idempotent commands (play/pause/seek) go through
    /// unchanged: repeating pause on an already-paused session is a no-op.
    private var lastSkipAt: Date?
    private static let skipDebounce: TimeInterval = 0.3

    /// Set when a follower's transport command was dropped because no live
    /// owner would ever execute it. Views surface a "Play Here" prompt instead
    /// of leaving the button looking broken (sync-audit-4 B2). Cleared as soon
    /// as a live owner reappears.
    @Published private(set) var lastCommandHitDeadOwner = false

    /// Returns false when the command was dropped. Twin of desktop
    /// SyncEngine.route.
    @discardableResult
    private func route(_ cmd: SyncCommand) -> Bool {
        if coordinator.role.isOwner {
            applyCommand(cmd)
            return true
        }
        // Only the owner drains the commands collection. With no live owner the
        // docs pile up unread and every tap silently does nothing, forever —
        // and patchMirror is already skipped for an expired lease, so the UI
        // doesn't even twitch. Drop it and let the UI offer "Play Here".
        guard hasLiveRemoteOwner else {
            lastCommandHitDeadOwner = true
            return false
        }
        switch cmd {
        case .next, .previous:
            let now = Date()
            if let last = lastSkipAt, now.timeIntervalSince(last) < Self.skipDebounce {
                return false
            }
            lastSkipAt = now
        default: break
        }
        commands.send(cmd)
        patchMirror(cmd)
        return true
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
        case .setLoop(let on):
            pb.loop = on
        case .next, .previous, .playTrack:
            return  // target track unknown until the owner's snapshot arrives
        case .requestStatus:
            return  // not a transport command — never routed through here
        }
        mirror = pb
    }
}
