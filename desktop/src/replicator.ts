// Two-way library replication against users/{uid}/library (+ Storage audio).
//
// Down: any cloud track missing locally streams into the music dir (.part →
// rename, no torn files), then a rescan heals ghosts.
// Up: any local file with no cloud metadata match (yt, then normalized name)
// uploads binary-first, metadata-last — listeners only ever see tracks whose
// audio is fully in Storage. Same invariant as LibraryReplicator.swift.
import {
  Firestore, collection, doc, onSnapshot, setDoc, serverTimestamp, Unsubscribe,
} from "firebase/firestore";
import {
  FirebaseStorage, ref as storageRef, getDownloadURL, uploadBytes,
} from "firebase/storage";
import * as fs from "fs";
import * as path from "path";
import { TrackMeta, DEVICE_ID } from "./protocol";
import { LocalTrack, norm } from "./player";

const sanitize = (name: string) => name.replace(/[<>:"/\\|?*]/g, "_").trim();
const MAX_UPLOAD = 100 * 1024 * 1024;
const MIME: Record<string, string> = {
  mp3: "audio/mpeg", m4a: "audio/m4a", aac: "audio/aac", opus: "audio/opus",
  ogg: "audio/ogg", webm: "audio/webm", wav: "audio/wav", flac: "audio/flac",
};

export class Replicator {
  status = "";
  onChange?: () => void;

  private unsub?: Unsubscribe;
  private meta = new Map<string, TrackMeta>();   // docId → meta (cloud truth)
  private downQ: TrackMeta[] = [];
  private downFails = new Map<string, number>(); // Storage path → attempts
  private busy = false;
  private uid = "";
  private musicDir = "";
  private lib: () => LocalTrack[] = () => [];
  private onFile: () => void = () => {};

  constructor(private db: Firestore, private storage: FirebaseStorage) {}

  start(uid: string, musicDir: string, lib: () => LocalTrack[], onFile: () => void) {
    this.stop();
    this.uid = uid; this.musicDir = musicDir; this.lib = lib; this.onFile = onFile;
    this.unsub = onSnapshot(collection(this.db, "users", uid, "library"), snap => {
      for (const ch of snap.docChanges()) {
        const m = ch.doc.data() as TrackMeta;
        if (ch.type === "removed") { this.meta.delete(ch.doc.id); continue; }
        this.meta.set(ch.doc.id, m);
        if (m.path && !this.hasLocally(m) && !this.downQ.some(q => q.path === m.path))
          this.downQ.push(m);
      }
      void this.pump();
    });
  }

  stop() {
    this.unsub?.(); this.unsub = undefined;
    this.meta.clear(); this.downQ = [];
  }

  /** Call after a library rescan — uploads anything the cloud lacks. */
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

    // Down first — cheap wins, and it fills the library used by upload dedupe.
    while (this.downQ.length) {
      const m = this.downQ.shift()!;
      if (this.hasLocally(m)) continue;
      try {
        this.status = `Downloading “${m.name}”…`; this.onChange?.();
        const url = await getDownloadURL(storageRef(this.storage, m.path));
        const res = await fetch(url);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const buf = Buffer.from(await res.arrayBuffer());
        const tag = m.yt ? ` [${m.yt}]` : "";
        const file = path.join(this.musicDir, `${sanitize(m.name)}${tag}.${m.ext}`);
        fs.writeFileSync(file + ".part", buf);
        fs.renameSync(file + ".part", file);
        this.downFails.delete(m.path);
        this.onFile();
      } catch (e) {
        // Re-queue up to 3 attempts — a transient network blip used to drop
        // the track until app restart. Past the cap it waits for the next
        // snapshot change instead of hot-looping.
        const n = (this.downFails.get(m.path) ?? 0) + 1;
        this.downFails.set(m.path, n);
        if (n < 3) this.downQ.push(m);
        console.log(`[replicator] down failed (attempt ${n}): ${m.name}`, e);
      }
    }

    // Up: local files unknown to the cloud.
    for (const t of this.lib()) {
      if (this.inCloud(t)) continue;
      try {
        const size = fs.statSync(t.path).size;
        if (size > MAX_UPLOAD) continue;
        const ext = path.extname(t.path).slice(1).toLowerCase();
        this.status = `Uploading “${t.name}”…`; this.onChange?.();
        const spath = `users/${this.uid}/audio/${t.id}.${ext}`;
        await uploadBytes(storageRef(this.storage, spath),
          fs.readFileSync(t.path), { contentType: MIME[ext] ?? "audio/mpeg" });
        const m: TrackMeta = { name: t.name, folder: t.folder, ext, path: spath, by: DEVICE_ID };
        if (t.yt) m.yt = t.yt;
        await setDoc(doc(this.db, "users", this.uid, "library", t.id),
          { ...m, at: serverTimestamp() });
        this.meta.set(t.id, m);
      } catch (e) { console.log(`[replicator] up failed: ${t.name}`, e); }
    }

    this.status = ""; this.busy = false; this.onChange?.();
  }
}
