// Two-way effects-settings sync — twin of musicApp/Sync/SettingsSync.swift.
// Doc: users/{uid}/sync/settings (singleton, same doc family as session).
//   { speed, bassDb, reverbPct, updatedBy, at }
// LWW is Firestore's own snapshot ordering, same as the session/playlist
// docs — `at` (ServerClock ms) is carried for parity/debugging, not compared
// client-side. `updatedBy` filters same-device echo.
import { Firestore, doc, setDoc, onSnapshot, Unsubscribe } from "firebase/firestore";
import { DEVICE_ID } from "./protocol";
import { serverClock } from "./serverClock";

export interface SettingsDoc {
  speed: number;     // playback rate multiplier
  bassDb: number;     // raw dB, same units both apps
  reverbPct: number;  // 0-100 — desktop's internal fx.reverb is a 0-1 fraction
  // Effects master switch (iOS effectsBypass / desktop fx.bypass). Without it
  // a device with effects OFF still published its stored slider values, and a
  // device with effects ON applied them audibly — and they contradicted
  // PlaybackState.rate, which IS bypass-adjusted (sync-audit-4 M10).
  // OPTIONAL on the wire: absent means "an old client wrote this", and the
  // safe reading of a doc from a client that had no concept of bypass is
  // "not bypassed", which is exactly how those values were being applied.
  bypass?: boolean;
}

export class SettingsSync {
  onRemote?: (s: SettingsDoc) => void;

  private unsub?: Unsubscribe;
  private uid = "";

  constructor(private db: Firestore) {}

  start(uid: string) {
    this.stop();
    this.uid = uid;
    this.unsub = onSnapshot(this.ref(), snap => {
      const d = snap.data();
      if (!d || d.updatedBy === DEVICE_ID) return;
      if (typeof d.speed !== "number" || typeof d.bassDb !== "number"
          || typeof d.reverbPct !== "number") return;
      this.onRemote?.({
        speed: d.speed, bassDb: d.bassDb, reverbPct: d.reverbPct,
        bypass: typeof d.bypass === "boolean" ? d.bypass : false,
      });
    });
  }

  stop() {
    this.unsub?.(); this.unsub = undefined;
    this.uid = "";
  }

  push(s: SettingsDoc) {
    if (!this.uid) return;
    void setDoc(this.ref(), { ...s, updatedBy: DEVICE_ID, at: serverClock.nowMs })
      .catch(() => {});
  }

  private ref() {
    return doc(this.db, "users", this.uid, "sync", "settings");
  }
}
