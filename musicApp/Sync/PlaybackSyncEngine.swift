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
        coordinator.onRemoteState = { [weak self] state in
            self?.handleRemote(state)
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
                }
            }
            .store(in: &bag)
    }

    private func handleRemote(_ state: SessionState) {
        mirror = state.playback

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
        isApplyingRemotePlaybackCommand = true
        defer { isApplyingRemotePlaybackCommand = false }
        
        switch cmd {
        case .play: player.resume()
        case .pause: player.pause()
        case .next: player.next()
        case .previous: player.previous()
        case .seek(let ms): player.seek(to: Double(ms) / 1000.0)
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


    private func claimSessionForLocalPlayback() {
        Task { @MainActor in
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
        if coordinator.role.isOwner { applyCommand(cmd) }
        else { commands.send(cmd) }
    }
}
