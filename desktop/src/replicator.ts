// Two-way library replication against users/{uid}/library — LINK-SYNC model.
//
// Free-plan Firebase has no Storage bucket, so no binaries move through the
// cloud. A library doc's `yt` id IS the track: any cloud track missing
// locally is downloaded HERE via yt-dlp (same pipeline the iOS app uses),
// named "<title> [<yt>].<ext>" so the scanner's identity chain picks it up.
// Up: any local file with no cloud metadata match (yt, then normalized name)
// gets a metadata-only doc — receiving devices fetch their own audio.
import {
  Firestore, collection, doc, onSnapshot, setDoc, serverTimestamp, Unsubscribe,
} from "firebase/firestore";
import * as path from "path";
import { TrackMeta, DEVICE_ID } from "./protocol";
import { LocalTrack, norm } from "./player";
import { downloadTrack } from "./download";

export class Replicator {
  status = "";
  onChange?: () => void;

  private unsub?: Unsubscribe;
  private meta = new Map<string, TrackMeta>();   // docId → meta (cloud truth)
  private downQ: TrackMeta[] = [];
  private downFails = new Map<string, number>(); // yt id → attempts
  private busy = false;
  private uid = "";
  private musicDir = "";
  private lib: () => LocalTrack[] = () => [];
  private onFile: () => void = () => {};

  constructor(private db: Firestore) {}

  start(uid: string, musicDir: string, lib: () => LocalTrack[], onFile: () => void) {
    this.stop();
    this.uid = uid; this.musicDir = musicDir; this.lib = lib; this.onFile = onFile;
    this.unsub = onSnapshot(collection(this.db, "users", uid, "library"), snap => {
      for (const ch of snap.docChanges()) {
        const m = ch.doc.data() as TrackMeta;
        if (ch.type === "removed") { this.meta.delete(ch.doc.id); continue; }
        this.meta.set(ch.doc.id, m);
        // Only yt-bearing tracks are fetchable in the link-sync model.
        if (m.yt && !this.hasLocally(m) && !this.downQ.some(q => q.yt === m.yt))
          this.downQ.push(m);
      }
      void this.pump();
    });
  }

  stop() {
    this.unsub?.(); this.unsub = undefined;
    this.meta.clear(); this.downQ = [];
  }

  /** Call after a library rescan — mirrors anything the cloud lacks. */
  syncUp() { void this.pump(); }

  private hasLocally(m: TrackMeta): boolean {
    return this.lib().some(t => (m.yt && t.yt === m.yt) || norm(t.name) === norm(m.name));
  }

  private inCloud(t: LocalTrack): boolean {
    for (const m of this.meta.values())
      if ((t.yt && m.yt === t.yt) || norm(m.name) === norm(t.name)) return true;
    return false;
  }

  private async pump() {
    if (this.busy || !this.uid) return;
    this.busy = true;

    // Down first — it fills the library used by upload dedupe.
    while (this.downQ.length) {
      const m = this.downQ.shift()!;
      if (!m.yt || this.hasLocally(m)) continue;
      try {
        this.status = `Downloading “${m.name}”…`; this.onChange?.();
        await downloadTrack(
          `https://www.youtube.com/watch?v=${m.yt}`, this.musicDir,
          p => { this.status = `“${m.name}” — ${p.label}`; this.onChange?.(); });
        this.downFails.delete(m.yt);
        this.onFile();
      } catch (e) {
        // Up to 3 attempts, then wait for the next snapshot instead of
        // hot-looping (covers both flaky network and missing yt-dlp).
        const n = (this.downFails.get(m.yt) ?? 0) + 1;
        this.downFails.set(m.yt, n);
        if (n < 3) this.downQ.push(m);
        this.status = e instanceof Error ? e.message : String(e);
        this.onChange?.();
        console.log(`[replicator] down failed (attempt ${n}): ${m.name}`, e);
      }
    }

    // Up: local files unknown to the cloud — metadata only, no binary.
    for (const t of this.lib()) {
      if (this.inCloud(t)) continue;
      try {
        const ext = path.extname(t.path).slice(1).toLowerCase();
        this.status = `Mirroring “${t.name}”…`; this.onChange?.();
        const m: TrackMeta = { name: t.name, folder: t.folder, ext, by: DEVICE_ID };
        if (t.yt) m.yt = t.yt;
        await setDoc(doc(this.db, "users", this.uid, "library", t.id),
          { ...m, at: serverTimestamp() });
        this.meta.set(t.id, m);
      } catch (e) { console.log(`[replicator] up failed: ${t.name}`, e); }
    }

    this.status = ""; this.busy = false; this.onChange?.();
  }
}
