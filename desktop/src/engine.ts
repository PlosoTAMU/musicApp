// Twin of Sync/PlaybackSyncEngine.swift. All local mutations flow through this
// class, so owner publishes are explicit and loop-free by construction.
import { Firestore } from "firebase/firestore";
import { SessionCoordinator } from "./coordinator";
import { QueueSync, rebase } from "./queueSync";
import { CommandBus, Command } from "./commandBus";
import { LocalPlayer, LocalTrack, scanLibrary, resolve, toRef } from "./player";
import {
  PlaybackState, SessionState, TrackRef, positionAt, sameId,
} from "./protocol";
import { serverClock } from "./serverClock";

export class SyncEngine {
  readonly player = new LocalPlayer();
  readonly queueSync: QueueSync;
  readonly commands: CommandBus;

  library: LocalTrack[] = [];
  ghostQueue: TrackRef[] = [];
  onChange?: () => void;
  onLibraryChange?: () => void;      // hook for the replicator's up-sync

  // Back-nav history — twin of AudioPlayerManager.previousQueue. Built only by
  // natural advance / "next" (trackEnded), NOT by a direct library click, so it
  // matches iOS play() which leaves previousQueue untouched. Owner-local, like
  // iOS (a fresh owner after handover starts with empty history).
  private history: LocalTrack[] = [];
  private static readonly HISTORY_MAX = 100;

  private pushHistory(t?: LocalTrack) {
    if (!t) return;
    this.history.push(t);
    if (this.history.length > SyncEngine.HISTORY_MAX) this.history.shift();
  }

  // Playlist wrap — twin of iOS isPlaylistMode. Armed by playAll(), so a played
  // playlist keeps going and wraps to the top when the queue drains. Owner-local
  // (not synced): the wrap just re-fills the shared queue, which followers see.
  // Cleared by a direct single-track play (playLocal) or clearQueue — exiting
  // "playlist mode" the same way iOS play(_:) does.
  private playlistLoop: LocalTrack[] | null = null;

  /** Injected by ui.ts — maps a yt id to the current crop window. */
  cropLookup: (yt?: string) => { startMs?: number; endMs?: number } = () => ({});

  private applyCrop(t: LocalTrack) {
    const { startMs, endMs } = this.cropLookup(t.yt);
    this.player.setCrop(startMs, endMs);
  }

  /** Re-apply crop after a metadata push so the live position stays correct. */
  refreshCurrentCrop() {
    if (this.player.current) this.applyCrop(this.player.current);
  }

  constructor(db: Firestore, readonly coord: SessionCoordinator) {
    this.queueSync = new QueueSync(db, () => coord.ref);
    this.commands = new CommandBus(db, () => coord.ref);

    this.player.onEnded = () => this.trackEnded();
    this.player.onChange = () => this.onChange?.();

    coord.onDeposed = () => {          // audio transfers, never double-plays
      this.player.pause();
      this.commands.stop();
    };
    coord.onRemote = s => this.handleRemote(s);

    // Anchor refresh — bounds follower extrapolation drift to ≤30 s.
    setInterval(() => {
      if (coord.role === "owner" && this.player.playing) this.publish();
    }, 30_000);

    let wasOnline = true;
    setInterval(() => {
      if (!wasOnline && coord.online) this.queueSync.onOnline();
      wasOnline = coord.online;
    }, 1_000);
  }

  loadLibrary(root: string) {
    this.library = scanLibrary(root);
    this.onChange?.();
    this.onLibraryChange?.();
  }

  becomeCommandTarget() {
    this.commands.start(cmd => this.applyLocal(cmd));
  }

  // ── Remote → local ──────────────────────────────────────────────────────

  private handleRemote(s: SessionState) {
    this.ghostQueue = s.queue.filter(r => !resolve(r, this.library));
    this.player.queue = s.queue
      .map(r => resolve(r, this.library))
      .filter((t): t is LocalTrack => !!t);
    this.onChange?.();
  }

  // ── Controls: one call site, both roles (command-bus bridge) ───────────

  play()  { this.route({ t: "play" }); }
  pause() { this.route({ t: "pause" }); }
  next()  { this.route({ t: "next" }); }
  prev()  { this.route({ t: "prev" }); }
  seekMs(ms: number) { this.route({ t: "seek", ms: Math.round(ms) }); }

  private route(cmd: Command) {
    if (this.coord.role === "owner") this.applyLocal(cmd);
    else this.commands.send(cmd);
  }

  private applyLocal(cmd: Command) {
    switch (cmd.t) {
      case "play": this.player.resume(); break;
      case "pause": this.player.pause(); break;
      case "next": this.trackEnded(); break;
      case "prev": this.goPrevious(); break;
      case "seek": this.player.seekMs(cmd.ms); break;
    }
    this.publish();
  }

  /** Twin of AudioPlayerManager.previous(): pop history and play it, re-queuing
   *  the current track at the front so forward nav returns to it. Empty history
   *  (or first track) falls back to restart, matching iOS. Owner-only; followers
   *  reach this by routing "prev" through the command bus. */
  private goPrevious() {
    if (this.coord.role !== "owner") return;
    const prev = this.history.pop();
    if (!prev) { this.player.seekMs(0); return; }
    const cur = this.player.current;
    if (cur) {
      const ref = toRef(cur);
      if (this.coord.demo) this.demoQueue(q => [ref, ...q]);
      else void this.queueSync.apply({ kind: "insert", ref, afterId: null },
        this.coord.remote?.queueVersion ?? 0);
    }
    this.applyCrop(prev);
    this.player.play(prev);
  }

  /** Owner playing the queue: CAS-pop heads; ghost heads are consumed and skipped. */
  private trackEnded() {
    if (this.coord.role !== "owner") return;
    // Loop: restart the same track instead of consuming the queue (also catches
    // the "next" command, matching iOS next()). publish() only re-anchors pos 0
    // for followers — same track ref, so no track change goes out.
    if (this.player.loop && this.player.current) {
      this.player.seekMs(0);
      this.player.resume();
      this.publish();
      return;
    }
    const remoteQ = this.coord.remote?.queue ?? [];
    const basis = this.coord.remote?.queueVersion ?? 0;
    for (const head of remoteQ) {
      const local = resolve(head, this.library);
      if (this.coord.demo) this.demoQueue(q => q.filter(r => r.id !== head.id));
      else void this.queueSync.apply({ kind: "consumeHead", expected: head.id }, basis);
      if (local) {
        this.pushHistory(this.player.current);   // remember what we're leaving
        this.applyCrop(local);
        this.player.play(local);
        this.publish();
        return;
      }
    }
    // Queue drained. In playlist mode, wrap to the top instead of stopping —
    // twin of iOS next()'s currentIndex = (i+1) % count.
    if (this.playlistLoop && this.playlistLoop.length) {
      const list = this.playlistLoop;
      this.pushHistory(this.player.current);
      this.applyCrop(list[0]);
      this.player.play(list[0]);
      const refs = list.slice(1).map(toRef);
      if (this.coord.demo) this.demoQueue(() => refs);
      else void this.queueSync.apply({ kind: "replaceAll", queue: refs },
        this.coord.remote?.queueVersion ?? 0);
      this.publish();
      return;
    }
    this.player.stop();
    this.publish();
  }

  /** Offline preview: queue lives in the in-memory session, no Firestore. */
  private demoQueue(mutate: (q: TrackRef[]) => TrackRef[]) {
    const s = this.coord.remote;
    if (!s) return;
    s.queue = mutate(s.queue);
    s.queueVersion += 1;
    this.onChange?.();
  }

  // ── Publish (owner truth) ───────────────────────────────────────────────

  private snapshot(): PlaybackState {
    const cur = this.player.current;
    const pb: PlaybackState = {
      playing: this.player.playing,
      pos: Math.round(this.player.posMs),
      anchor: serverClock.nowMs,
      rate: this.player.rateX1000,
      dur: Math.round(this.player.durMs),
      rev: 0,
    };
    if (cur) pb.track = toRef(cur);
    return pb;
  }

  publish() {
    if (this.coord.role === "owner") void this.coord.publishPlayback(this.snapshot());
  }

  // ── Local library playback: implicit takeover ──────────────────────────

  /** Click a library track → this device becomes the owner and plays it.
   *  A direct single-track play exits playlist wrap, matching iOS play(_:). */
  async playLocal(t: LocalTrack) {
    this.playlistLoop = null;
    if (this.coord.role !== "owner") {
      await this.coord.takeOver();
      this.becomeCommandTarget();
    }
    this.applyCrop(t);
    this.player.play(t);
    this.publish();
  }

  /** Play a whole list: first track now, rest replace the shared queue. Arms
   *  playlist wrap so playback continues past the queue and loops to the top. */
  async playAll(ts: LocalTrack[]) {
    if (!ts.length) return;
    await this.playLocal(ts[0]);   // clears playlistLoop…
    this.playlistLoop = ts;        // …then arm it with the full set
    const refs = ts.slice(1).map(toRef);
    if (this.coord.demo) { this.demoQueue(() => refs); return; }
    void this.queueSync.apply({ kind: "replaceAll", queue: refs },
      this.coord.remote?.queueVersion ?? 0);
  }

  /** Clear the shared queue and exit playlist wrap — twin of
   *  clearQueueAndExitPlaylist(). Owner-only (queue is session-shared). */
  clearQueue() {
    this.playlistLoop = null;
    if (this.coord.demo) { this.demoQueue(() => []); return; }
    void this.queueSync.apply({ kind: "replaceAll", queue: [] },
      this.coord.remote?.queueVersion ?? 0);
  }

  /** Append to the shared queue (intent op — safe against concurrent edits). */
  queueLocal(t: LocalTrack) {
    if (this.coord.demo) { this.demoQueue(q => [...q, toRef(t)]); return; }
    const remoteQ = this.coord.remote?.queue ?? [];
    const afterId = remoteQ.length ? remoteQ[remoteQ.length - 1].id : null;
    void this.queueSync.apply(
      { kind: "insert", ref: toRef(t), afterId },
      this.coord.remote?.queueVersion ?? 0);
  }

  queueRemove(id: string) {
    if (this.coord.demo) { this.demoQueue(q => q.filter(r => r.id !== id)); return; }
    void this.queueSync.apply(
      { kind: "remove", id }, this.coord.remote?.queueVersion ?? 0);
  }

  /** Drag-to-reorder: place `id` after `afterId` (null = front). */
  queueMove(id: string, afterId: string | null) {
    if (this.coord.demo) {
      this.demoQueue(q => rebase({ kind: "move", id, afterId }, q) ?? q);
      return;
    }
    void this.queueSync.apply(
      { kind: "move", id, afterId }, this.coord.remote?.queueVersion ?? 0);
  }

  // ── Handover ────────────────────────────────────────────────────────────

  /** "Play Here": refuse before the epoch bump if the track is a ghost here.
   *  `forcePlay` = Bluetooth handoff: the old owner paused when its headphones
   *  dropped, so the session reads "paused" — but the intent is continuation. */
  async takeOverHere(forcePlay = false) {
    const pb = this.coord.remote?.playback;
    if (pb?.track && !resolve(pb.track, this.library))
      throw new Error(`“${pb.track.name}” is not in this device's library`);

    const pre = await this.coord.takeOver();
    const prePb = pre.playback;
    const posMs = positionAt(prePb, serverClock.nowMs);

    if (prePb.track) {
      const local = resolve(prePb.track, this.library)!;
      this.player.queue = pre.queue
        .map(r => resolve(r, this.library))
        .filter((t): t is LocalTrack => !!t);
      this.applyCrop(local);
      this.player.play(local, posMs, !(prePb.playing || forcePlay));
    }
    this.becomeCommandTarget();
    this.publish();
  }

  // ── Mirror helpers ──────────────────────────────────────────────────────

  // Display slew — every fresh anchor moves raw extrapolation by up to
  // ±500 ms; jumping the shown position each snapshot reads as stutter.
  // Errors ≤ SNAP_MS converge via rate warp (≤ ±MAX_WARP, aimed at ~CONVERGE_MS);
  // beyond that (seek/track change) or on pause, snap.
  private static readonly SNAP_MS = 750;
  private static readonly MAX_WARP = 0.04;
  private static readonly CONVERGE_MS = 2_000;
  private disp: { pos: number; at: number; trackId: string | null } | null = null;

  mirrorPositionMs(): number {
    const pb = this.coord.remote?.playback;
    if (!pb) { this.disp = null; return 0; }
    const target = positionAt(pb, serverClock.nowMs);
    const now = Date.now();
    const trackId = pb.track?.id ?? null;
    const d = this.disp;
    if (!pb.playing || !d || d.trackId !== trackId
        || Math.abs(target - d.pos) > SyncEngine.SNAP_MS) {
      this.disp = { pos: target, at: now, trackId };
      return target;
    }
    // Advance displayed at session rate, warped toward the target.
    const dt = now - d.at;
    const ideal = d.pos + (dt * pb.rate) / 1000;
    const err = target - ideal;
    const warp = Math.max(-SyncEngine.MAX_WARP,
      Math.min(SyncEngine.MAX_WARP, err / SyncEngine.CONVERGE_MS));
    const pos = ideal + dt * warp;
    this.disp = { pos, at: now, trackId };
    return pos;
  }

  isGhost(ref: TrackRef): boolean {
    return this.ghostQueue.some(g => sameId(g.id, ref.id));
  }
}
