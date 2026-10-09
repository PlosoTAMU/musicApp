// Per-track DJ/effects memory: bypass belongs to the song, not global fx.v1.
// Older stored entries did not include bypass; those must default to DJ off.
import { DEFAULT_FX, TrackFxStore } from "../src/trackFx";

let n = 0;
function eq(name: string, got: unknown, want: unknown) {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) throw new Error(`${name}: got ${g}, want ${w}`);
}

class MemStorage {
  data: Record<string, string> = {};
  getItem(k: string) { return this.data[k] ?? null; }
  setItem(k: string, v: string) { this.data[k] = v; }
}

const storage = new MemStorage();
const store = new TrackFxStore(storage);

eq("missing track defaults to DJ off/bypassed",
  store.get("SONG-A"), DEFAULT_FX);

store.set("SONG-A", { ...DEFAULT_FX, bypass: false });
eq("DJ on persists for that song",
  new TrackFxStore(storage).get("song-a").bypass, false);
eq("other songs still default DJ off",
  new TrackFxStore(storage).get("song-b").bypass, true);

store.set("SONG-A", DEFAULT_FX);
eq("default settings delete per-track entry",
  storage.data["fx.tracks.v1"], "{}");

storage.data["fx.tracks.v1"] = JSON.stringify({
  "old-song": { speed: 1.2, pitch: 0, reverb: 0, bass: 0 },
});
const old = new TrackFxStore(storage).get("OLD-SONG");
eq("old entries without bypass decode as DJ off", old.bypass, true);
eq("old entries keep existing slider memory", old.speed, 1.2);

console.log(`trackFx.test.ts: ${n} assertions passed`);
