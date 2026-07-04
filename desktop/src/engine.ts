// Twin of Sync/PlaybackSyncEngine.swift. All local mutations flow through this
// class, so owner publishes are explicit and loop-free by construction.
import { Firestore } from "firebase/firestore";
import { SessionCoordinator } from "./coordinator";
import { QueueSync } from "./queueSync";
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
      case "prev": this.player.seekMs(0); break;
      case "seek": this.player.seekMs(cmd.ms); break;
    }
    this.publish();
  }

  /** Owner playing the queue: CAS-pop heads; ghost heads are consumed and skipped. */
  private trackEnded() {
    if (this.coord.role !== "owner") return;
    const remoteQ = this.coord.remote?.queue ?? [];
    const basis = this.coord.remote?.queueVersion ?? 0;
    for (const head of remoteQ) {
      const local = resolve(head, this.library);
      if (this.coord.demo) this.demoQueue(q => q.filter(r => r.id !== head.id));
      else void this.queueSync.apply({ kind: "consumeHead", expected: head.id }, basis);
      if (local) {
        this.player.play(local);
        this.publish();
        return;
      }
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

  /** Click a library track → this device becomes the owner and plays it. */
  async playLocal(t: LocalTrack) {
    if (this.coord.role !== "owner") {
      await this.coord.takeOver();
      this.becomeCommandTarget();
    }
    this.player.play(t);
    this.publish();
  }

  /** Play a whole list: first track now, rest replace the shared queue. */
  async playAll(ts: LocalTrack[]) {
    if (!ts.length) return;
    await this.playLocal(ts[0]);
    const refs = ts.slice(1).map(toRef);
    if (this.coord.demo) { this.demoQueue(() => refs); return; }
    void this.queueSync.apply({ kind: "replaceAll", queue: refs },
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
      this.player.play(local, posMs, !(prePb.playing || forcePlay));
    }
    this.becomeCommandTarget();
    this.publish();
  }

  // ── Mirror helpers ──────────────────────────────────────────────────────

  mirrorPositionMs(): number {
    const pb = this.coord.remote?.playback;
    return pb ? positionAt(pb, serverClock.nowMs) : 0;
  }

  isGhost(ref: TrackRef): boolean {
    return this.ghostQueue.some(g => sameId(g.id, ref.id));
  }
}
