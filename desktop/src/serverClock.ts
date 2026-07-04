// Twin of Sync/ServerClock.swift — NTP-style offset, median of 9 samples.
import {
  Firestore, doc, setDoc, getDocFromServer, serverTimestamp, Timestamp,
} from "firebase/firestore";
import { DEVICE_ID } from "./protocol";

class ServerClock {
  private samples: number[] = [];
  offsetMs = 0;

  get isSynced() { return this.samples.length > 0; }
  get nowMs() { return Date.now() + this.offsetMs; }

  ingest(serverMs: number, sendMs: number, recvMs: number) {
    this.samples.push(serverMs - (sendMs + recvMs) / 2);
    if (this.samples.length > 9) this.samples.splice(0, this.samples.length - 9);
    this.offsetMs = [...this.samples].sort((a, b) => a - b)[this.samples.length >> 1];
  }

  /** Presence doc doubles as liveness + clock sample (2-RTT window; median absorbs it). */
  async sample(db: Firestore, uid: string) {
    const ref = doc(db, "users", uid, "sync", `presence_${DEVICE_ID}`);
    const send = Date.now();
    await setDoc(ref, { at: serverTimestamp() });
    const snap = await getDocFromServer(ref);
    const recv = Date.now();
    const at = snap.get("at") as Timestamp | undefined;
    if (at) this.ingest(at.toMillis(), send, recv);
  }

  async prime(db: Firestore, uid: string) {
    if (this.isSynced) return;
    for (let i = 0; i < 3; i++) {
      try { await this.sample(db, uid); return; }
      catch { await new Promise(r => setTimeout(r, 500 * (i + 1))); }
    }
  }
}

export const serverClock = new ServerClock();
