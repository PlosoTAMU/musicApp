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

  ingest(serverMs: number, sendMs: number, ackMs: number) {
    this.samples.push(serverMs - (sendMs + ackMs) / 2);
    if (this.samples.length > 9) this.samples.splice(0, this.samples.length - 9);
    this.offsetMs = [...this.samples].sort((a, b) => a - b)[this.samples.length >> 1];
  }

  /** Presence doc doubles as liveness + clock sample. The server stamps `at`
   *  during the WRITE commit, so the sample window is send→ack only; the
   *  follow-up read just fetches the stamped value — its latency must never
   *  enter the offset math (it would bias every sample low by ~RTT/2). */
  async sample(db: Firestore, uid: string) {
    const ref = doc(db, "users", uid, "sync", `presence_${DEVICE_ID}`);
    const send = Date.now();
    await setDoc(ref, { at: serverTimestamp() });
    const ack = Date.now();
    const snap = await getDocFromServer(ref);
    const at = snap.get("at") as Timestamp | undefined;
    if (at) this.ingest(at.toMillis(), send, ack);
  }

  /** 3 sequential samples so the very first median has spread to reject; a
   *  failed sample retries once after a short backoff, then moves on — a
   *  partial prime beats blocking connect. */
  async prime(db: Firestore, uid: string) {
    if (this.isSynced) return;
    for (let i = 0; i < 3; i++) {
      try { await this.sample(db, uid); }
      catch {
        await new Promise(r => setTimeout(r, 400));
        try { await this.sample(db, uid); } catch { /* keep what landed */ }
      }
    }
  }
}

export const serverClock = new ServerClock();
