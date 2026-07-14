// Crop editor modal — desktop twin of musicApp/CropSongSheet.swift.
// Preview runs on a second throwaway <audio> (like iOS's throwaway
// AVAudioPlayer) looping inside [start, end]; the main player is paused for
// the duration. Apply hands the window (or null = uncropped) to ui.ts, which
// writes the library doc. All DOM, no Firestore.
import { clampCrop, clampStart, clampEnd, cropForSave, parseTime, fmtTime } from "./fxMath";

export interface CropSheetOpts {
  name: string;
  fileUrl: string;
  crop: { startMs?: number; endMs?: number };
  volume: number;
  /** Pause the main player if it's playing here; return whether it was. */
  pauseMain: () => boolean;
  resumeMain: () => void;
  onApply: (r: { startMs: number; endMs: number } | null) => void;
}

export function showCropSheet(o: CropSheetOpts) {
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.innerHTML = `
    <div class="modal-card crop-card">
      <h4></h4>
      <div class="crop-meta"><span class="crop-full">Loading…</span><span class="crop-len"></span></div>
      <input class="crop-seek" type="range" min="0" max="1" value="0" step="0.1" />
      <div class="crop-times"><span class="crop-pos">0:00</span><span class="crop-rem">-0:00</span></div>
      <div class="crop-transport">
        <button class="row-btn crop-rew" title="Back 5s">−5s</button>
        <button class="pill crop-play">Play</button>
        <button class="row-btn crop-fwd" title="Forward 5s">+5s</button>
        <button class="row-btn crop-hear-end" title="Hear the last 3s">End</button>
      </div>
      <div class="crop-row"><span>Start</span>
        <input class="crop-start" type="range" min="0" max="1" step="0.1" />
        <button class="crop-chip crop-start-t">0:00</button></div>
      <div class="crop-row"><span>End</span>
        <input class="crop-end" type="range" min="0" max="1" step="0.1" />
        <button class="crop-chip crop-end-t">0:00</button></div>
      <div class="modal-actions">
        <button class="link crop-reset">Reset</button>
        <span class="spacer" style="flex:1"></span>
        <button class="link modal-cancel">Cancel</button>
        <button class="pill modal-ok">Apply Crop</button>
      </div>
    </div>`;

  const q = <T extends HTMLElement>(sel: string) => overlay.querySelector(sel) as T;
  q<HTMLElement>("h4").textContent = `Crop “${o.name}”`;

  const seek = q<HTMLInputElement>(".crop-seek");
  const startR = q<HTMLInputElement>(".crop-start");
  const endR = q<HTMLInputElement>(".crop-end");

  let full = 0, start = 0, end = 0;
  const wasPlaying = o.pauseMain();

  const audio = new Audio(o.fileUrl);
  audio.preload = "auto";
  audio.volume = o.volume;

  const fill = (el: HTMLInputElement, v: number) =>
    el.style.setProperty("--fill", `${full > 0 ? (v / full) * 100 : 0}%`);

  const syncUi = () => {
    q(".crop-len").textContent = `✂ ${fmtTime(Math.max(0, end - start))}`;
    startR.value = String(start);
    endR.value = String(end);
    q(".crop-start-t").textContent = fmtTime(start);
    q(".crop-end-t").textContent = fmtTime(end);
    fill(startR, start);
    fill(endR, end);
  };

  const tick = () => {
    if (audio.currentTime >= end && end > 0) audio.currentTime = start; // loop the window
    seek.value = String(audio.currentTime);
    fill(seek, audio.currentTime);
    q(".crop-pos").textContent = fmtTime(audio.currentTime);
    q(".crop-rem").textContent = `-${fmtTime(Math.max(0, end - audio.currentTime))}`;
    q(".crop-play").textContent = audio.paused ? "Play" : "Pause";
  };
  const loopTimer = setInterval(() => { if (!audio.paused) tick(); }, 40);

  // Esc cancels the sheet — but not while a time chip's inline input (or a
  // focused slider) has focus; those handle their own keys.
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape" && (e.target as HTMLElement).tagName !== "INPUT") close();
  };
  document.addEventListener("keydown", onKey, true);

  const close = () => {
    clearInterval(loopTimer);
    audio.pause();
    audio.removeAttribute("src");
    overlay.remove();
    document.removeEventListener("keydown", onKey, true);
    if (wasPlaying) o.resumeMain();
  };

  const playFrom = (t: number) => {
    audio.currentTime = Math.max(start, Math.min(t, end));
    if (audio.paused) void audio.play().catch(() => {});
    tick();
  };

  audio.onloadedmetadata = () => {
    full = Number.isFinite(audio.duration) ? audio.duration : 0;
    ({ start, end } = clampCrop((o.crop.startMs ?? 0) / 1000,
      o.crop.endMs != null ? o.crop.endMs / 1000 : full, full));
    seek.max = startR.max = endR.max = String(full);
    q(".crop-full").textContent = `Full ${fmtTime(full)}`;
    audio.currentTime = start;
    syncUi();
    tick();
  };
  audio.onerror = () => { q(".crop-full").textContent = "Unable to read this audio file"; };

  q(".crop-play").onclick = () => {
    if (audio.paused) playFrom(audio.currentTime > start ? audio.currentTime : start);
    else { audio.pause(); tick(); }
  };
  q(".crop-rew").onclick = () => playFrom(audio.currentTime - 5);
  q(".crop-fwd").onclick = () => playFrom(audio.currentTime + 5);
  q(".crop-hear-end").onclick = () => playFrom(end - 3);
  seek.oninput = () => playFrom(Number(seek.value));

  // Sliders clamp like the iOS ranges; releasing previews the boundary
  // (start → from start, end → the last 3 s), like iOS's editing-ended hooks.
  startR.oninput = () => { start = clampStart(Number(startR.value), end); syncUi(); };
  startR.onchange = () => playFrom(start);
  endR.oninput = () => { end = clampEnd(Number(endR.value), start, full); syncUi(); };
  endR.onchange = () => playFrom(end - 3);

  // Tappable time chips → inline "m:ss" input (twin of the iOS text fields).
  const editChip = (chip: HTMLButtonElement, apply: (secs: number) => void) => {
    chip.onclick = () => {
      const inp = document.createElement("input");
      inp.className = "crop-chip-input";
      inp.value = chip.textContent ?? "";
      chip.replaceWith(inp);
      inp.focus();
      inp.select();
      let done = false;
      const finish = (commit: boolean) => {
        if (done) return;
        done = true;
        const t = commit ? parseTime(inp.value) : undefined;
        inp.replaceWith(chip);
        if (t !== undefined) apply(t);
        syncUi();
      };
      inp.onkeydown = e => {
        if (e.key === "Enter") finish(true);
        if (e.key === "Escape") finish(false);
      };
      inp.onblur = () => finish(true);
    };
  };
  editChip(q<HTMLButtonElement>(".crop-start-t"), t => { start = clampStart(t, end); playFrom(start); });
  editChip(q<HTMLButtonElement>(".crop-end-t"), t => { end = clampEnd(t, start, full); playFrom(end - 3); });

  q(".crop-reset").onclick = () => { start = 0; end = full; syncUi(); playFrom(0); };
  q<HTMLButtonElement>(".modal-cancel").onclick = close;
  q<HTMLButtonElement>(".modal-ok").onclick = () => {
    if (!full) { close(); return; } // metadata never loaded — nothing to save
    o.onApply(cropForSave(start, end, full));
    close();
  };
  overlay.onmousedown = e => { if (e.target === overlay) close(); };

  document.body.appendChild(overlay);
}
