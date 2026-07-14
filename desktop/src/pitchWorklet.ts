// AudioWorklet entry — bundled separately (dist/pitchWorklet.js) and loaded
// via audioWorklet.addModule from a Blob URL. Runs in the
// AudioWorkletGlobalScope: no DOM, no require — everything bundles in.
import { PitchShifter } from "./pitchShifter";

// The DOM lib has no worklet-scope types; declare the minimum we touch.
declare class AudioWorkletProcessor {
  readonly port: MessagePort;
  constructor();
}
declare function registerProcessor(name: string, ctor: unknown): void;

class PulsorPitchProcessor extends AudioWorkletProcessor {
  static get parameterDescriptors() {
    return [{
      name: "semitones", defaultValue: 0, minValue: -12, maxValue: 12,
      automationRate: "k-rate" as const,
    }];
  }

  private shifter = new PitchShifter();

  process(inputs: Float32Array[][], outputs: Float32Array[][],
          parameters: Record<string, Float32Array>): boolean {
    const input = inputs[0], output = outputs[0];
    if (!output?.length) return true;
    if (!input?.length) { for (const o of output) o.fill(0); return true; }
    this.shifter.setSemitones(parameters.semitones?.[0] ?? 0);
    this.shifter.process(input, output);
    return true;
  }
}

registerProcessor("pulsor-pitch", PulsorPitchProcessor);
