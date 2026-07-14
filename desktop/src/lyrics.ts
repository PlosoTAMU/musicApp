// Lyrics fetch + shared cache. Twin of musicApp/Lyrics/ on iOS.
//
// Doc contract: users/{uid}/library/{TRACKID}/lyrics/current — LyricsDoc in
// LyricsModels.swift. FIELD NAMES ARE THE CONTRACT. Doc ids are uppercased:
// iOS UUID strings are always uppercase, so matching case here means both
// sides share one cache doc per track. Lives in a subcollection so the
// library onSnapshot listener never streams lyric payloads.
//
// Lookup: memory → Firestore (home-wide cache) → LRCLIB, write-back on fetch.
// Fuzzy search hits are only accepted within ±5s of the full file duration —
// the guard that keeps remix/live/sped-up versions from matching the studio
// original's lyrics.
import { Firestore, doc, getDoc, setDoc } from "firebase/firestore";

export interface LyricLine {
  timeMs: number; // FILE-relative, like LRC itself
  text: string;
}

export interface LyricsDoc {
  plain?: string;
  synced?: string; // raw LRC text
  source: string;
  offsetMs: number; // line active when fileTimeMs >= timeMs + offsetMs
  instrumental: boolean;
  fetchedAtMs: number;
  notFound: boolean;
}

const NOT_FOUND_RETRY_MS = 7 * 24 * 3600 * 1000;
const DURATION_TOLERANCE_S = 5;

// ── LRC parsing ────────────────────────────────────────────────────────────

const TAG_RE = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
const OFFSET_RE = /^\[offset:\s*([+-]?\d+)\]$/i;

const tagToMs = (m: RegExpExecArray): number => {
  const mins = parseInt(m[1], 10);
  const secs = parseInt(m[2], 10);
  let frac = 0;
  if (m[3] !== undefined) {
    // ".5" = 500ms, ".55" = 550ms, ".555" = 555ms
    frac = parseInt(m[3], 10) * (m[3].length === 1 ? 100 : m[3].length === 2 ? 10 : 1);
  }
  return (mins * 60 + secs) * 1000 + frac;
};

/** Time-sorted lines; multiple tags per line supported; [offset:] honored
 *  (LRC spec: positive = lyrics earlier). Empty lines kept — they mark
 *  instrumental gaps. Mirrors LRCParser.parse in Swift. */
export function parseLRC(lrc: string): LyricLine[] {
  const stamped: LyricLine[] = [];
  let globalOffset = 0;

  for (const rawLine of lrc.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;

    const off = OFFSET_RE.exec(line);
    if (off) { globalOffset = parseInt(off[1], 10) || 0; continue; }

    // Only leading, contiguous [mm:ss.xx] tags count as timestamps.
    TAG_RE.lastIndex = 0;
    let end = 0;
    const times: number[] = [];
    let m: RegExpExecArray | null;
    while ((m = TAG_RE.exec(line)) && m.index === end) {
      times.push(tagToMs(m));
      end = TAG_RE.lastIndex;
    }
    if (!times.length) continue;

    const text = line.slice(end).trim();
    for (const t of times) stamped.push({ timeMs: Math.max(0, t - globalOffset), text });
  }

  return stamped.sort((a, b) => a.timeMs - b.timeMs);
}

/** Last line whose (timeMs + offset) has passed — binary search; null before
 *  the first line. Same contract as LyricsView.activeIndex in Swift. */
export function activeIndex(lines: LyricLine[], fileMs: number, offsetMs: number): number | null {
  let lo = 0, hi = lines.length - 1, ans: number | null = null;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (lines[mid].timeMs + offsetMs <= fileMs) { ans = mid; lo = mid + 1; }
    else hi = mid - 1;
  }
  return ans;
}

// ── Query building (twin of LyricsQueryBuilder) ────────────────────────────

const JUNK_WORDS = [
  "official", "video", "audio", "lyric", "visualizer", "visualiser",
  "hd", "hq", "4k", "8k", "mv", "m/v", "explicit", "remaster",
  "remastered", "color coded", "colour coded", "full version",
  "out now", "premiere", "music video", "sub español", "legendado",
];

export function cleanTitle(raw: string): string {
  return raw
    .replace(/[\(\[【][^\(\)\[\]【】]*[\)\]】]/g, seg => {
      const s = seg.toLowerCase();
      return JUNK_WORDS.some(w => s.includes(w)) ? "" : seg;
    })
    .replace(/\s{2,}/g, " ")
    .trim();
}

const stripFeat = (s: string): string =>
  s.replace(/\s*[\(\[]?\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]+[\)\]]?/gi, "")
   .replace(/\s{2,}/g, " ")
   .trim();

interface Candidate { artist: string; track: string; }

/** Ordered (artist, track) guesses from a "Artist - Title"-ish name. Empty
 *  artist = fuzzy-search-only candidate. Desktop names are filenames, which
 *  came from iOS Download names (raw YouTube titles) or the user's own files. */
function candidates(name: string): Candidate[] {
  const out: Candidate[] = [];
  const add = (artist: string, track: string) => {
    const a = artist.trim(), t = track.trim();
    if (!t) return;
    if (!out.some(c => c.artist === a && c.track === t)) out.push({ artist: a, track: t });
  };

  const clean = cleanTitle(name);
  const parts = clean.split(" - ").map(p => p.trim()).filter(Boolean);
  if (parts.length >= 2) {
    const track = parts.slice(1).join(" - ");
    add(parts[0], track);
    add(parts[0], stripFeat(track));
    // Reversed "Title - Artist" ordering happens in the wild.
    add(parts[parts.length - 1], parts.slice(0, -1).join(" - "));
  } else {
    add("", clean);
    add("", stripFeat(clean));
  }
  return out;
}

// ── LRCLIB client ──────────────────────────────────────────────────────────

interface Rec {
  duration?: number;
  instrumental?: boolean;
  plainLyrics?: string | null;
  syncedLyrics?: string | null;
}

async function apiJSON<T>(url: string): Promise<T | null> {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

const durationOK = (rec: Rec, fileSec: number | undefined, strict: boolean): boolean => {
  if (fileSec === undefined) return !strict;
  if (rec.duration === undefined) return !strict;
  return Math.abs(rec.duration - fileSec) <= DURATION_TOLERANCE_S;
};

const recScore = (r: Rec): number =>
  (r.syncedLyrics ? 2 : 0) + (r.plainLyrics ? 1 : 0);

async function fetchFromLRCLIB(name: string, durationSec?: number): Promise<LyricsDoc> {
  let hit: Rec | null = null;

  const cands = candidates(name);
  for (const q of cands) {
    if (!q.artist) continue;
    const p = new URLSearchParams({ artist_name: q.artist, track_name: q.track });
    if (durationSec !== undefined) p.set("duration", String(durationSec));
    const rec = await apiJSON<Rec>(`https://lrclib.net/api/get?${p}`);
    if (rec && durationOK(rec, durationSec, false)) { hit = rec; break; }
  }

  // Fuzzy fallback only behind the duration guard — without a file duration
  // the top search hit is a coin flip, so skip it entirely.
  if (!hit && durationSec !== undefined) {
    for (const q of cands.slice(0, 2)) {
      const query = q.artist ? `${q.artist} ${q.track}` : q.track;
      const recs = (await apiJSON<Rec[]>(
        `https://lrclib.net/api/search?${new URLSearchParams({ q: query })}`)) ?? [];
      const best = recs
        .filter(r => recScore(r) > 0 || r.instrumental === true)
        .filter(r => durationOK(r, durationSec, true))
        .sort((a, b) => recScore(b) - recScore(a))[0];
      if (best) { hit = best; break; }
    }
  }

  const synced = hit?.syncedLyrics?.trim() || undefined;
  const plain = hit?.plainLyrics?.trim() || undefined;
  const instrumental = hit?.instrumental === true;
  return {
    plain, synced,
    source: "lrclib",
    offsetMs: 0,
    instrumental,
    fetchedAtMs: Date.now(),
    notFound: !(instrumental || synced || plain),
  };
}

// ── Store ──────────────────────────────────────────────────────────────────

export class LyricsStore {
  private memory = new Map<string, LyricsDoc>();

  /** Fired when a background offset re-read finds a fresher value. Wire this
   *  in ui.ts to update the display without a full lyrics reload. */
  onOffset?: (trackId: string, offsetMs: number) => void;

  constructor(private db: Firestore) {}

  /** Silently re-reads offsetMs from Firestore after a memory cache hit.
   *  If another device nudged the offset, surfaces the change via onOffset. */
  private async refreshOffset(uid: string, key: string, currentOffset: number): Promise<void> {
    if (!uid) return;
    const snap = await getDoc(this.ref(uid, key)).catch(() => null);
    if (!snap?.exists()) return;
    const fresh = (snap.data() as Partial<LyricsDoc>).offsetMs ?? 0;
    if (fresh === currentOffset) return;
    const cached = this.memory.get(key);
    if (cached) cached.offsetMs = fresh;
    this.onOffset?.(key, fresh);
  }

  /** uid "" (demo/offline) skips Firestore — LRCLIB + memory only.
   *  `force` bypasses memory + Firestore and refetches from LRCLIB (the
   *  "Try Again" path — twin of iOS load(force:)); the fresh result still
   *  writes back so every device inherits the retry. */
  async get(uid: string, trackId: string, name: string, durationSec?: number,
            force = false): Promise<LyricsDoc> {
    const key = trackId.toUpperCase();

    const cached = force ? undefined : this.memory.get(key);
    if (cached && !this.expiredNotFound(cached)) {
      void this.refreshOffset(uid, key, cached.offsetMs);
      return cached;
    }

    if (uid && !force) {
      const snap = await getDoc(this.ref(uid, key)).catch(() => null);
      if (snap?.exists()) {
        const d: LyricsDoc = {
          source: "lrclib", offsetMs: 0, instrumental: false,
          fetchedAtMs: 0, notFound: false,
          ...(snap.data() as Partial<LyricsDoc>),
        };
        if (!this.expiredNotFound(d)) {
          this.memory.set(key, d);
          return d;
        }
      }
    }

    const fresh = await fetchFromLRCLIB(name, durationSec);
    this.memory.set(key, fresh);
    // ignoreUndefinedProperties (firebase.ts) drops the optional fields.
    if (uid) await setDoc(this.ref(uid, key), fresh).catch(() => {});
    return fresh;
  }

  /** Persist a manual alignment nudge so every device inherits it. */
  async setOffset(uid: string, trackId: string, offsetMs: number): Promise<void> {
    const key = trackId.toUpperCase();
    const cached = this.memory.get(key);
    if (cached) cached.offsetMs = offsetMs;
    if (uid) await setDoc(this.ref(uid, key), { offsetMs }, { merge: true }).catch(() => {});
  }

  private expiredNotFound(d: LyricsDoc): boolean {
    return d.notFound && Date.now() - d.fetchedAtMs > NOT_FOUND_RETRY_MS;
  }

  private ref(uid: string, key: string) {
    return doc(this.db, "users", uid, "library", key, "lyrics", "current");
  }
}
