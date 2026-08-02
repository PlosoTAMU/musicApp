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
const MIN_BAR = 1;

/** Draws the 100-bar edge visualizer centered in a `boxSize`×`boxSize` region
 *  of the canvas (canvas itself should be larger, to leave room for bars to
 *  extend outward). Twin of EdgeVisualizerView's Canvas body. */
export function drawEdgeVisualizer(
  ctx: CanvasRenderingContext2D, boxSize: number, cornerRadius: number,
  maxBarLen: number, bins: Float32Array, colors: string[] | null,
): void {
  const cx = ctx.canvas.clientWidth / 2, cy = ctx.canvas.clientHeight / 2;
  const halfBox = boxSize / 2;
  const straightEdge = boxSize - 2 * cornerRadius;
  const spacing = straightEdge / BARS_PER_SIDE;

  let barIndex = 0;
  const drawBar = (x: number, y: number, dx: number, dy: number) => {
    const v = bins[barIndex];
    const len = Math.max(MIN_BAR, v * maxBarLen);
    const rgb = colors ? colors[barIndex % colors.length] : FALLBACK_COLOR;
    ctx.strokeStyle = `rgba(${rgb},${(0.55 + v * 0.45).toFixed(3)})`;
    ctx.lineWidth = Math.max(1.5, spacing * 0.5);
    ctx.beginPath();
    ctx.moveTo(x, y);
    ctx.lineTo(x + dx * len, y + dy * len);
    ctx.stroke();
    barIndex++;
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
