// Per-track effect memory — twin of AudioPlayerManager.TrackSettings
// (track_settings.json): speed/pitch/reverb/bass restore when a track plays.
// Local-only on BOTH platforms (never synced); volume and bypass stay global,
// also like iOS. Storage is injected so the store is Node-testable.

export interface TrackFx { speed: number; pitch: number; reverb: number; bass: number }
export const DEFAULT_FX: TrackFx = { speed: 1, pitch: 0, reverb: 0, bass: 0 };

interface StorageLike {
  getItem(k: string): string | null;
  setItem(k: string, v: string): void;
}

export class TrackFxStore {
  private map: Record<string, TrackFx>;

  constructor(private storage: StorageLike, private key = "fx.tracks.v1") {
    try { this.map = JSON.parse(storage.getItem(key) ?? "{}"); }
    catch { this.map = {}; }
  }

  /** Absent track → iOS defaults (1× / 0 st / 0 % / 0 dB). */
  get(id: string): TrackFx {
    return { ...DEFAULT_FX, ...this.map[id.toLowerCase()] };
  }

  set(id: string, fx: TrackFx) {
    const k = id.toLowerCase();
    if (fx.speed === DEFAULT_FX.speed && fx.pitch === DEFAULT_FX.pitch
        && fx.reverb === DEFAULT_FX.reverb && fx.bass === DEFAULT_FX.bass) {
      delete this.map[k]; // default settings = no entry, same restore outcome
    } else {
      this.map[k] = { ...fx };
    }
    this.storage.setItem(this.key, JSON.stringify(this.map));
  }
}
