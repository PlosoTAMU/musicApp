// Two-way playlist sync — twin of musicApp/Sync/PlaylistSync.swift.
// Doc contract: users/{uid}/playlists/{PLAYLISTID}
//   { name, tracks: [{id, name, yt?}], updatedAtMs, by, deleted? }
// LWW per playlist (updatedAtMs from ServerClock); tombstones for deletes.
// Tracks carry name+yt so entries resolve to local files through the same
// id → yt → name chain the queue uses.
import {
  Firestore, collection, doc, onSnapshot, setDoc, Unsubscribe,
} from "firebase/firestore";
import { DEVICE_ID } from "./protocol";
import { serverClock } from "./serverClock";

export interface PlaylistTrack {
  id: string;
  name: string;
  yt?: string;
}

export interface CloudPlaylist {
  id: string;
  name: string;
  tracks: PlaylistTrack[];
  updatedAtMs: number;
}

export class PlaylistSync {
  /** Live (non-tombstoned) playlists, name-sorted. */
  playlists: CloudPlaylist[] = [];
  onChange?: () => void;

  private map = new Map<string, CloudPlaylist & { deleted: boolean }>();
  private unsub?: Unsubscribe;
  private uid = "";

  constructor(private db: Firestore) {}

  start(uid: string) {
    this.stop();
    this.uid = uid;
    this.unsub = onSnapshot(collection(this.db, "users", uid, "playlists"), snap => {
      for (const ch of snap.docChanges()) {
        if (ch.type === "removed") { this.map.delete(ch.doc.id); continue; }
        const d = ch.doc.data();
        this.map.set(ch.doc.id, {
          id: ch.doc.id,
          name: (d.name as string) ?? "",
          tracks: (d.tracks as PlaylistTrack[]) ?? [],
          updatedAtMs: (d.updatedAtMs as number) ?? 0,
          deleted: d.deleted === true,
        });
      }
      this.playlists = [...this.map.values()]
        .filter(p => !p.deleted)
        .sort((a, b) => a.name.localeCompare(b.name));
      this.onChange?.();
    });
  }

  stop() {
    this.unsub?.(); this.unsub = undefined;
    this.map.clear();
    this.playlists = [];
    this.uid = "";
  }

  get(id: string): CloudPlaylist | undefined {
    const p = this.map.get(id);
    return p && !p.deleted ? p : undefined;
  }

  async create(name: string): Promise<string> {
    return this.createWith(name, []);
  }

  /** Create a playlist already holding `tracks` in a single write — lets
   *  "New playlist… + add this song" avoid a create→addTrack snapshot race. */
  async createWith(name: string, tracks: PlaylistTrack[]): Promise<string> {
    const id = crypto.randomUUID().toUpperCase();
    await this.write(id, name, tracks);
    return id;
  }

  async addTrack(id: string, t: PlaylistTrack): Promise<void> {
    const p = this.get(id);
    if (!p || p.tracks.some(x => x.id.toUpperCase() === t.id.toUpperCase())) return;
    await this.write(id, p.name, [...p.tracks, t]);
  }

  async removeTrack(id: string, trackId: string): Promise<void> {
    const p = this.get(id);
    if (!p) return;
    await this.write(id, p.name,
      p.tracks.filter(x => x.id.toUpperCase() !== trackId.toUpperCase()));
  }

  async rename(id: string, name: string): Promise<void> {
    const p = this.get(id);
    if (!p || !name.trim()) return;
    await this.write(id, name.trim(), p.tracks);
  }

  /** Persist a reordered track list (drag-to-reorder in the open playlist). */
  async reorder(id: string, tracks: PlaylistTrack[]): Promise<void> {
    const p = this.get(id);
    if (!p) return;
    await this.write(id, p.name, tracks);
  }

  /** Tombstone, not delete — an offline phone must not resurrect it. */
  async remove(id: string): Promise<void> {
    if (!this.uid) return;
    await setDoc(doc(this.db, "users", this.uid, "playlists", id),
      { deleted: true, updatedAtMs: serverClock.nowMs, by: DEVICE_ID },
      { merge: true }).catch(() => {});
  }

  private async write(id: string, name: string, tracks: PlaylistTrack[]): Promise<void> {
    if (!this.uid) return;
    await setDoc(doc(this.db, "users", this.uid, "playlists", id),
      { name, tracks, updatedAtMs: serverClock.nowMs, by: DEVICE_ID })
      .catch(() => {});
  }
}
