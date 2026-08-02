// Edge visualizer — twin of musicApp's EdgeVisualizerView: FFT bars wrapped
// around the album art, colored from the art's dominant colors, art itself
// pulsing on the beat (driven by the existing BeatFeed pulse, see ui.ts).

const FALLBACK_COLOR = "241,43,38"; // --red

/** Downsampled dominant-color extraction — port of ContentView.swift's
 *  extractDominantColors. Pure: takes raw RGBA pixel data, no DOM/canvas
 *  dependency, so it's testable without a browser. */
export function extractDominantColors(data: Uint8ClampedArray, width: number, height: number): string[] {
  const counts = new Map<string, { r: number; g: number; b: number; count: number }>();

  for (let y = 0; y < height; y += 2) {
    for (let x = 0; x < width; x += 2) {
      const i = (y * width + x) * 4;
      const r = data[i], g = data[i + 1], b = data[i + 2];
      const brightness = (r + g + b) / 3 / 255;
      if (brightness <= 0.2 || brightness >= 0.9) continue;

      const qR = Math.floor(r / 64), qG = Math.floor(g / 64), qB = Math.floor(b / 64);
      const key = `${qR}-${qG}-${qB}`;
      const existing = counts.get(key);
      if (existing) {
        existing.count++;
      } else {
        counts.set(key, { r, g, b, count: 1 });
      }
    }
  }

  const sorted = [...counts.values()].sort((a, b) => b.count - a.count);
  if (sorted.length === 0) return [FALLBACK_COLOR];
  return sorted.slice(0, 8).map(c => `${c.r},${c.g},${c.b}`);
}

const BARS_PER_SIDE = 25; // 100 total, matches EDGE_BINS in beat.ts

function parseRgb(s: string): [number, number, number] {
  const [r, g, b] = s.split(",").map(Number);
  return [r, g, b];
}

/** Standard RGB→HSL, each channel 0-1. Used to reproduce drawBarFast's
 *  per-bar hue/saturation/brightness modulation on top of a flat "r,g,b". */
function rgbToHsl(r: number, g: number, b: number): [number, number, number] {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h: number;
  switch (max) {
    case r: h = ((g - b) / d + (g < b ? 6 : 0)); break;
    case g: h = (b - r) / d + 2; break;
    default: h = (r - g) / d + 4;
  }
  return [h / 6, s, l];
}

/** Draws the 100-bar edge visualizer centered in a `boxSize`×`boxSize` region
 *  of the canvas (canvas itself should be larger, to leave room for bars to
 *  extend outward). Port of drawBarFast: bars below the 0.02 noise floor are
 *  skipped entirely, line width scales with the bar's own value (not bar
 *  spacing), strong bars (>0.35) get an extra translucent glow stroke
 *  underneath, and color is hue/saturation/brightness-modulated per bar
 *  rather than a flat tint. */
export function drawEdgeVisualizer(
  ctx: CanvasRenderingContext2D, boxSize: number, cornerRadius: number,
  maxBarLen: number, bins: Float32Array, colors: string[] | null,
): void {
  const cx = ctx.canvas.clientWidth / 2, cy = ctx.canvas.clientHeight / 2;
  const halfBox = boxSize / 2;
  const straightEdge = boxSize - 2 * cornerRadius;
  const spacing = straightEdge / BARS_PER_SIDE;
  const palette = (colors && colors.length ? colors : [FALLBACK_COLOR])
    .map(parseRgb).map(([r, g, b]) => rgbToHsl(r, g, b));

  ctx.lineCap = "round";
  let barIndex = 0;
  const drawBar = (x: number, y: number, dx: number, dy: number) => {
    const v = bins[barIndex];
    const [h0, s0, l0] = palette[barIndex % palette.length];
    barIndex++;
    if (v <= 0.02) return;

    const len = v * maxBarLen;
    const hue = (((h0 + v * 0.05 - 0.025) % 1) + 1) % 1;
    const sat = Math.min(1, Math.max(0.7, s0 + v * 0.3));
    const light = Math.min(1, Math.max(0.5, l0) + v * 0.5);
    const alpha = 0.75 + v * 0.25;
    const color = `hsl(${(hue * 360).toFixed(1)},${(sat * 100).toFixed(1)}%,${(light * 100).toFixed(1)}%)`;
    const lineWidth = 2.5 + v * 1.5;

    ctx.beginPath();
    ctx.moveTo(x, y);
    ctx.lineTo(x + dx * len, y + dy * len);

    if (v > 0.35) {
      ctx.globalAlpha = alpha * 0.3;
      ctx.lineWidth = lineWidth + 2;
      ctx.strokeStyle = color;
      ctx.stroke();
    }
    ctx.globalAlpha = alpha;
    ctx.lineWidth = lineWidth;
    ctx.strokeStyle = color;
    ctx.stroke();
  };

  // TOP
  for (let i = 0; i < BARS_PER_SIDE; i++) {
    drawBar(cx - halfBox + cornerRadius + spacing * (i + 0.5), cy - halfBox, 0, -1);
  }
  // RIGHT
  for (let i = 0; i < BARS_PER_SIDE; i++) {
    drawBar(cx + halfBox, cy - halfBox + cornerRadius + spacing * (i + 0.5), 1, 0);
  }
  // BOTTOM
  for (let i = 0; i < BARS_PER_SIDE; i++) {
    drawBar(cx + halfBox - cornerRadius - spacing * (i + 0.5), cy + halfBox, 0, 1);
  }
  // LEFT
  for (let i = 0; i < BARS_PER_SIDE; i++) {
    drawBar(cx - halfBox, cy + halfBox - cornerRadius - spacing * (i + 0.5), -1, 0);
  }
  ctx.globalAlpha = 1;
}

/** Samples the currently-loaded art image's dominant colors. Returns `null`
 *  (never throws) if the canvas is CORS-tainted — i.ytimg.com's CORS headers
 *  are unverified, so this is the expected fallback path, not an error. */
export function sampleArtColors(img: HTMLImageElement): string[] | null {
  try {
    const size = 50;
    const cv = document.createElement("canvas");
    cv.width = size; cv.height = size;
    const ctx = cv.getContext("2d");
    if (!ctx) return null;
    ctx.drawImage(img, 0, 0, size, size);
    const { data } = ctx.getImageData(0, 0, size, size); // throws if tainted
    return extractDominantColors(data, size, size);
  } catch {
    return null;
  }
}
