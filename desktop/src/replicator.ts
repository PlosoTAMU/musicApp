// Two-way library replication against users/{uid}/library — LINK-SYNC model.
//
// Free-plan Firebase has no Storage bucket, so no binaries move through the
// cloud. A library doc's `yt` id IS the track: any cloud track missing
// locally is downloaded HERE via yt-dlp (same pipeline the iOS app uses),
// named "<title> [<yt>].<ext>" so the scanner's identity chain picks it up.
// Up: any local file with no cloud metadata match (yt, then normalized name)
// gets a metadata-only doc — receiving devices fetch their own audio.
import {
  Firestore, collection, doc, onSnapshot, setDoc, updateDoc, serverTimestamp,
  deleteField, Unsubscribe,
} from "firebase/firestore";
import * as path from "path";
import * as fs from "fs";
import { TrackMeta, DEVICE_ID } from "./protocol";
import { LocalTrack, norm } from "./player";
import { downloadTrack } from "./download";

/** Same illegal-char lens the iOS side normalizes through — applied when we
 *  WRITE filenames, so pushed-back names round-trip identically. */
const sanitize = (s: string) => s.replace(/[<>:"/\\|?*]/g, "_").trim();

export class Replicator {
  status = "";
  onChange?: () => void;

  /** Fired when crop metadata changes for the currently playing track. */
  onCropChanged?: (yt: string) => void;

  private static readonly SHADOW_KEY = "sync.meta.shadow";
  // Last-synced name/folder per yt — the 3-way merge base that tells a disk
  // edit here apart from a cloud edit elsewhere. Persisted so offline disk
  // edits still push after a restart.
  private shadow: Record<string, { name: string; folder: string }> =
    JSON.parse(localStorage.getItem(Replicator.SHADOW_KEY) ?? "{}");
  private saveShadow() {
    localStorage.setItem(Replicator.SHADOW_KEY, JSON.stringify(this.shadow));
  }

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
        const prev = this.meta.get(ch.doc.id);
        this.meta.set(ch.doc.id, m);
        if (m.yt && (prev?.cropStartMs !== m.cropStartMs || prev?.cropEndMs !== m.cropEndMs))
          this.onCropChanged?.(m.yt);
        // Only live, yt-bearing tracks are fetchable; tombstones also cancel
        // any queued fetch.
        if (m.yt && m.deleted) this.downQ = this.downQ.filter(q => q.yt !== m.yt);
        else if (m.yt && !this.hasLocally(m) && !this.downQ.some(q => q.yt === m.yt))
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

  cropFor(yt?: string): { startMs?: number; endMs?: number } {
    if (!yt) return {};
    for (const m of this.meta.values())
      if (m.yt === yt && !m.deleted)
        return { startMs: m.cropStartMs, endMs: m.cropEndMs };
    return {};
  }

  /** Push a crop window (null = uncropped) to the track's library doc — twin
   *  of iOS pushMeta's crop fields (absent = FieldValue.delete()). The
   *  snapshot echo re-applies it locally via onCropChanged. */
  async setCrop(yt: string, r: { startMs: number; endMs: number } | null) {
    if (!this.uid) return;
    const entry = [...this.meta.entries()].find(([, m]) => m.yt === yt && !m.deleted);
    if (!entry) return;
    await updateDoc(doc(this.db, "users", this.uid, "library", entry[0]), {
      cropStartMs: r ? r.startMs : deleteField(),
      cropEndMs: r ? r.endMs : deleteField(),
      metaAt: serverTimestamp(), metaBy: DEVICE_ID,
    }).catch(() => {});
  }

  private hasLocally(m: TrackMeta): boolean {
    return this.lib().some(t => (m.yt && t.yt === m.yt) || norm(t.name) === norm(m.name));
  }

  /** Metadata reconciliation, run every pump:
   *  - tombstone → delete the local file
   *  - local file gone but shadow says it was here → tombstone the doc
   *  - cloud name/folder changed → rename/move the local file
   *  - disk name/folder changed → push to the doc
   *  Cloud wins when both changed (home-scale LWW). */
  private reconcile() {
    for (const [docId, m] of this.meta) {
      if (!m.yt) continue;
      const yt = m.yt;
      const local = this.lib().find(t => t.yt === yt);
      const sh = this.shadow[yt];
      const ref = doc(this.db, "users", this.uid, "library", docId);

      if (m.deleted) {
        if (local && fs.existsSync(local.path)) {
          try { fs.unlinkSync(local.path); this.onFile(); }
          catch (e) { console.log(`[replicator] delete failed: ${m.name}`, e); }
        }
        if (sh) { delete this.shadow[yt]; this.saveShadow(); }
        continue;
      }

      if (!local) {
        // Shadow says this track lived here and the file is gone → the user
        // deleted it on disk. (First run has an empty shadow, so a library
        // that simply hasn't downloaded yet can't mass-tombstone.)
        if (sh) {
          void updateDoc(ref, {
            deleted: true, metaAt: serverTimestamp(), metaBy: DEVICE_ID,
          }).catch(() => {});
          delete this.shadow[yt]; this.saveShadow();
        }
        continue;
      }

      const localChanged = !!sh && (local.name !== sh.name || local.folder !== sh.folder);
      const cloudChanged = !sh || m.name !== sh.name || m.folder !== sh.folder;

      if (localChanged && (!cloudChanged || m.metaBy === DEVICE_ID)) {
        // Disk edit here (rename or move in the file manager) → push up.
        void updateDoc(ref, {
          name: local.name, folder: local.folder,
          metaAt: serverTimestamp(), metaBy: DEVICE_ID,
        }).catch(() => {});
        this.shadow[yt] = { name: local.name, folder: local.folder };
        this.saveShadow();
      } else if (cloudChanged) {
        // Cloud edit (or first sight) → apply down. Empty cloud folder means
        // "no opinion" (iOS-minted doc): keep the file where it is and adopt
        // the local folder into the doc — desktop is the folder authority.
        const wantName = sanitize(m.name);
        const dir = m.folder
          ? path.join(this.musicDir, sanitize(m.folder))
          : path.dirname(local.path);
        const target = path.join(dir, `${wantName} [${yt}]${path.extname(local.path)}`);
        if (target !== local.path) {
          try {
            fs.mkdirSync(dir, { recursive: true });
            fs.renameSync(local.path, target);
            this.onFile();
          } catch (e) {
            // Playing file can be locked on Windows — retried next pump.
            console.log(`[replicator] meta apply failed: ${m.name}`, e);
            continue;  // shadow untouched → retried
          }
        }
        if (!m.folder) {
          void updateDoc(ref, {
            folder: local.folder, metaAt: serverTimestamp(), metaBy: DEVICE_ID,
          }).catch(() => {});
        }
        this.shadow[yt] = { name: m.name, folder: m.folder || local.folder };
        this.saveShadow();
      }
    }
  }

  private async pump() {
    if (this.busy || !this.uid) return;
    this.busy = true;

    this.reconcile();

    // Down first — it fills the library used by upload dedupe.
    while (this.downQ.length) {
      const m = this.downQ.shift()!;
      if (!m.yt || this.hasLocally(m)) continue;
      try {
        this.status = `Downloading "${m.name}"…`; this.onChange?.();
        await downloadTrack(
          `https://www.youtube.com/watch?v=${m.yt}`, this.musicDir,
          p => { this.status = `"${m.name}" — ${p.label}`; this.onChange?.(); });
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
      if (!fs.existsSync(t.path)) continue;  // raced a reconcile deletion
      const match = [...this.meta.entries()].find(([, m]) =>
        (t.yt && m.yt === t.yt) || norm(m.name) === norm(t.name));
      const ext = path.extname(t.path).slice(1).toLowerCase();
      try {
        if (match && match[1].deleted && t.yt) {
          // Manual re-download of a deleted track → revive the doc in place.
          this.status = `Restoring "${t.name}"…`; this.onChange?.();
          await setDoc(doc(this.db, "users", this.uid, "library", match[0]), {
            name: t.name, folder: t.folder, ext, yt: t.yt, by: DEVICE_ID,
            deleted: false, at: serverTimestamp(),
            metaAt: serverTimestamp(), metaBy: DEVICE_ID,
          });
          this.shadow[t.yt] = { name: t.name, folder: t.folder };
          this.saveShadow();
          continue;
        }
        if (match) {
          if (t.yt && !this.shadow[t.yt]) {
            this.shadow[t.yt] = { name: match[1].name, folder: match[1].folder || t.folder };
            this.saveShadow();
          }
          continue;
        }
        this.status = `Mirroring "${t.name}"…`; this.onChange?.();
        const m: TrackMeta = { name: t.name, folder: t.folder, ext, by: DEVICE_ID };
        if (t.yt) m.yt = t.yt;
        await setDoc(doc(this.db, "users", this.uid, "library", t.id), {
          ...m, at: serverTimestamp(),
          deleted: false, metaAt: serverTimestamp(), metaBy: DEVICE_ID,
        });
        this.meta.set(t.id, m);
        if (t.yt) { this.shadow[t.yt] = { name: t.name, folder: t.folder }; this.saveShadow(); }
      } catch (e) { console.log(`[replicator] up failed: ${t.name}`, e); }
    }

    this.status = ""; this.busy = false; this.onChange?.();
  }
}
