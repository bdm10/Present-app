/**
 * Fits silence around recorded speech so the finished session lasts exactly the
 * requested duration. Works in whole samples so the voice and music stems end on
 * the same sample.
 */

export interface TimingInput {
  sampleRate: number;
  targetSeconds: number;
  /** Decoded length of each speech clip, in samples. */
  speechSamples: number[];
  /** Relative pause the script asked for after each clip (seconds). The last one is ignored. */
  pauseHints: number[];
  leadInSeconds: number;
  tailSeconds: number;
  minPauseSeconds?: number;
  maxPauseSeconds?: number;
}

export interface TimingPlan {
  leadInSamples: number;
  pauseSamples: number[]; // length = clips - 1
  tailSamples: number;
  totalSamples: number;
  /** Start of each clip in seconds from the beginning of the session. */
  speechStartSeconds: number[];
  /** [start, end] seconds of each clip, for music ducking. */
  speechIntervals: [number, number][];
}

export class SpeechTooLongError extends Error {
  constructor(public readonly overSeconds: number) {
    super(`Script is ${overSeconds.toFixed(1)}s too long for the chosen duration`);
    this.name = "SpeechTooLongError";
  }
}

const MIN_LEAD_IN = 3;
const MIN_TAIL = 8;

export function planTiming(input: TimingInput): TimingPlan {
  const sr = input.sampleRate;
  const n = input.speechSamples.length;
  if (n === 0) throw new Error("No speech to time");
  const minPause = input.minPauseSeconds ?? 1.2;
  const maxPause = input.maxPauseSeconds ?? 75;
  const target = Math.round(input.targetSeconds * sr);
  const speech = input.speechSamples.reduce((a, b) => a + b, 0);

  let leadIn = Math.round(input.leadInSeconds * sr);
  let tail = Math.round(input.tailSeconds * sr);
  const gaps = n - 1;
  const minNeeded = Math.round(minPause * sr) * gaps;

  let available = target - speech - leadIn - tail;
  if (available < minNeeded) {
    // Give back some of the musical intro/outro before declaring the script too long.
    leadIn = Math.min(leadIn, Math.round(MIN_LEAD_IN * sr));
    tail = Math.min(tail, Math.round(MIN_TAIL * sr));
    available = target - speech - leadIn - tail;
    if (available < minNeeded) {
      throw new SpeechTooLongError((minNeeded - available) / sr);
    }
  }

  const hints = Array.from({ length: gaps }, (_, i) => Math.max(0.5, input.pauseHints[i] ?? 3));
  let pausesSec: number[] = [];
  if (gaps > 0) {
    const availSec = available / sr;
    const fill = (k: number) => hints.map((h) => Math.min(maxPause, Math.max(minPause, h * k)));
    const sum = (arr: number[]) => arr.reduce((a, b) => a + b, 0);
    if (sum(fill(1e9)) <= availSec) {
      // Even every pause at its maximum leaves time over: spread the rest evenly.
      const extra = (availSec - maxPause * gaps) / gaps;
      pausesSec = hints.map(() => maxPause + extra);
    } else {
      // Binary-search the scale factor so the clamped pauses fill the available time.
      let lo = 0;
      let hi = 1;
      while (sum(fill(hi)) < availSec) hi *= 2;
      for (let i = 0; i < 80; i++) {
        const mid = (lo + hi) / 2;
        if (sum(fill(mid)) < availSec) lo = mid;
        else hi = mid;
      }
      pausesSec = fill(hi);
    }
  } else {
    tail += available;
  }

  const pauseSamples = pausesSec.map((p) => Math.round(p * sr));
  // Put any rounding remainder into the tail so the total is exact.
  const used = leadIn + speech + pauseSamples.reduce((a, b) => a + b, 0) + tail;
  tail += target - used;
  if (tail < 0) {
    // Only possible through rounding on tiny inputs; take it from the last pause.
    const last = pauseSamples.length - 1;
    if (last >= 0) pauseSamples[last] += tail;
    tail = 0;
  }

  const speechStartSeconds: number[] = [];
  const speechIntervals: [number, number][] = [];
  let cursor = leadIn;
  for (let i = 0; i < n; i++) {
    speechStartSeconds.push(cursor / sr);
    speechIntervals.push([cursor / sr, (cursor + input.speechSamples[i]) / sr]);
    cursor += input.speechSamples[i] + (i < gaps ? pauseSamples[i] : 0);
  }

  return {
    leadInSamples: leadIn,
    pauseSamples,
    tailSamples: tail,
    totalSamples: target,
    speechStartSeconds,
    speechIntervals,
  };
}

/** Lead-in (music only) and tail lengths that suit each duration and theme. */
export function framingFor(durationMinutes: number, theme: string): { leadIn: number; tail: number; fadeOut: number } {
  const sleep = theme === "sleep";
  const leadIn = durationMinutes <= 5 ? 6 : 10;
  const tail = sleep ? (durationMinutes <= 5 ? 25 : 45) : durationMinutes <= 5 ? 14 : 22;
  const fadeOut = sleep ? Math.min(40, tail) : Math.min(16, tail);
  return { leadIn, tail, fadeOut };
}
