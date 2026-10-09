// Pulse-trainer Web Worker — feature extraction, training and inference run
// here so a multi-minute training run never stalls the 60 fps UI. Bundled to
// dist/pulseWorker.js (iife) and loaded from a Blob URL by pulseAI.ts.
// Cancel = terminate(); the training loop is synchronous by design.
import { extractFeatures, encodeFeatures, decodeFeatures } from "./pulseFeatures";
import { PulseNet, PulseModelJSON, trainPulseNet, SongData } from "./pulseModel";
import { Clip, curveToEvents } from "./pulseCurve";

export type WorkerReq =
  | { id: number; type: "features"; pcm: Float32Array }
  | { id: number; type: "train"; songs: { id: string; feat: ArrayBuffer; clips: Clip[] }[] }
  | { id: number; type: "predict"; model: PulseModelJSON; feat: ArrayBuffer };

const ctx = self as unknown as {
  onmessage: ((e: MessageEvent<WorkerReq>) => void) | null;
  postMessage(msg: unknown, transfer?: Transferable[]): void;
};

ctx.onmessage = e => {
  const m = e.data;
  try {
    if (m.type === "features") {
      const buf = encodeFeatures(extractFeatures(m.pcm));
      ctx.postMessage({ id: m.id, ok: true, buf }, [buf]);
    } else if (m.type === "train") {
      const songs: SongData[] = [];
      for (const s of m.songs) {
        const ft = decodeFeatures(s.feat);
        if (ft) songs.push({ id: s.id, ft, clips: s.clips });
      }
      const { json } = trainPulseNet(songs, {
        onProgress: p => ctx.postMessage({ id: m.id, progress: p }),
      });
      ctx.postMessage({ id: m.id, ok: true, model: json });
    } else if (m.type === "predict") {
      const net = PulseNet.fromJSON(m.model);
      const ft = decodeFeatures(m.feat);
      if (!net || !ft) throw new Error("Model or feature cache is out of date");
      ctx.postMessage({ id: m.id, ok: true, events: curveToEvents(net.predict(ft), net.cal) });
    }
  } catch (err) {
    ctx.postMessage({ id: m.id, ok: false, error: String((err as Error)?.message ?? err) });
  }
};
