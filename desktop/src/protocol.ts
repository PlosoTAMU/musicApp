// Wire-format twin of musicApp/Sync/SyncModels.swift.
// FIELD NAMES ARE THE CONTRACT — any change here must land in Swift too.

export interface TrackRef {
  id: string;        // UUID string (uppercase from iOS; compare case-insensitively)
  name: string;
  folder: string;
  yt?: string;       // YouTube videoId — strongest cross-device key
}

export interface PlaybackState {
  track?: TrackRef;
  playing: boolean;
  pos: number;       // media position ms at the anchor instant
  anchor: number;    // ServerClock ms when pos was true
  rate: number;      // effective rate ×1000
  dur: number;       // cropped track length ms
  rev: number;       // per-epoch monotonic
}

// Shared-secret model: the secret derives one Firebase account, so every
// device shares ONE uid. The session is a singleton doc at
// users/{uid}/sync/session — no pairing, no membership. Device-level
// ownership (who plays audio) is still epoch-fenced.
/** Bluetooth-handoff beacon: the owner's headphones just disconnected. Any
 *  device that gains an audio output within the window auto-takes-over —
 *  "switch the Bluetooth connection to switch playback". */
export interface Handoff {
  by: string;    // device that lost its route
  atMs: number;  // ServerClock ms when it happened
}

export interface SessionState {
  epoch: number;
  ownerDeviceID: string;   // "" = idle, nobody owns playback yet
  leaseMs: number;
  playback: PlaybackState;
  queue: TrackRef[];
  queueVersion: number;
  updatedBy: string;
  handoff?: Handoff;
}

/** Doc shape under users/{uid}/library — written by LibraryReplicator.swift.
 *  LINK-SYNC model: `yt` is the source of truth; each device downloads its
 *  own audio via yt-dlp. `path` only exists on legacy docs from the old
 *  Storage-upload model and is no longer read. */
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

export const LEASE_TTL_MS = 45_000;
export const HANDOFF_WINDOW_MS = 60_000;

/** True when another device's headphones dropped recently enough that an
 *  audio-output gain HERE should auto-continue playback. */
export const handoffActive = (s: SessionState, nowMs: number): boolean =>
  !!s.handoff && s.handoff.by !== DEVICE_ID &&
  nowMs - s.handoff.atMs < HANDOFF_WINDOW_MS;

/** Same extrapolation as PlaybackState.positionMs(atServerMs:) in Swift. */
export const positionAt = (pb: PlaybackState, serverNowMs: number): number =>
  pb.playing
    ? pb.pos + (Math.max(0, serverNowMs - pb.anchor) * pb.rate) / 1000
    : pb.pos;

export const leaseExpired = (s: SessionState, serverNowMs: number): boolean =>
  serverNowMs > s.leaseMs + LEASE_TTL_MS;

/** Nothing is playing anywhere in the session — no owner, or the owner
 *  published an empty playback (queue drained / stopped). Queue-adds while
 *  idle start playback instead of parking (twin of iOS addToQueue /
 *  queuePlaylist's currentTrack == nil branch). */
export const sessionIdle = (s: SessionState | undefined): boolean =>
  !s || !s.ownerDeviceID || !s.playback.track;

// Queue ops are CLIENT-LOCAL intents (rebased against the live queue inside a
// transaction, never serialized) — extending this union does not touch the
// wire contract. append/injectFront twin queuePlaylist/injectAtFrontOfQueue.
export type QueueOp =
  | { kind: "insert"; ref: TrackRef; afterId: string | null }
  | { kind: "remove"; id: string }
  | { kind: "move"; id: string; afterId: string | null }
  | { kind: "consumeHead"; expected: string }
  | { kind: "replaceAll"; queue: TrackRef[] }
  | { kind: "append"; refs: TrackRef[] }
  | { kind: "injectFront"; refs: TrackRef[]; removeIds: string[] };

export const sameId = (a: string, b: string) =>
  a.toLowerCase() === b.toLowerCase();

// Stable per-install device id (twin of SyncDevice.id).
export const DEVICE_ID: string = (() => {
  const KEY = "sync.device.id";
  let v = localStorage.getItem(KEY);
  if (!v) {
    v = crypto.randomUUID().toUpperCase();
    localStorage.setItem(KEY, v);
  }
  return v;
})();

export const FENCED = new Error("fenced");
export const QUEUE_STALE = new Error("queueStale");
