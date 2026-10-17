import { spawn } from "node:child_process";
import fs from "node:fs";

export const SAMPLE_RATE = 44100;

/** Target loudness for each stem. Music sits well under the voice even at full volume. */
export const VOICE_LUFS = -19;
export const MUSIC_LUFS = -25;
/** How far the music dips while the voice is speaking (linear gain, ~ -7 dB). */
export const DUCK_GAIN = 0.45;

export class FfmpegError extends Error {}

export function run(cmd: string, args: string[], opts: { input?: Buffer } = {}): Promise<{ stdout: Buffer; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ["pipe", "pipe", "pipe"] });
    const out: Buffer[] = [];
    let err = "";
    child.stdout.on("data", (d: Buffer) => out.push(d));
    child.stderr.on("data", (d: Buffer) => {
      err += d.toString();
      if (err.length > 200_000) err = err.slice(-100_000);
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve({ stdout: Buffer.concat(out), stderr: err });
      else reject(new FfmpegError(`${cmd} exited with ${code}: ${err.slice(-1500)}`));
    });
    if (opts.input) child.stdin.end(opts.input);
    else child.stdin.end();
  });
}

export async function probeDuration(file: string): Promise<number> {
  const { stdout } = await run("ffprobe", [
    "-v", "error",
    "-show_entries", "format=duration",
    "-of", "default=noprint_wrappers=1:nokey=1",
    file,
  ]);
  const d = Number(stdout.toString().trim());
  if (!Number.isFinite(d) || d <= 0) throw new FfmpegError(`Could not read duration of ${file}`);
  return d;
}

/** Decodes any audio file to raw signed 16-bit PCM at 44.1 kHz. Returns frames (samples per channel). */
export async function decodeToRaw(input: string, outRaw: string, channels: 1 | 2 = 1): Promise<number> {
  await run("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-y",
    "-i", input,
    "-vn", "-ac", String(channels), "-ar", String(SAMPLE_RATE),
    "-f", "s16le", outRaw,
  ]);
  return fs.statSync(outRaw).size / (2 * channels);
}

function parseIntegratedLoudness(stderr: string): number {
  const summary = stderr.slice(stderr.lastIndexOf("Summary:"));
  const m = summary.match(/I:\s+(-?[\d.]+|-inf)\s+LUFS/);
  if (!m || m[1] === "-inf") return -70;
  return Number(m[1]);
}

export async function measureLoudnessRaw(raw: string, channels: 1 | 2): Promise<number> {
  const { stderr } = await run("ffmpeg", [
    "-hide_banner", "-nostats",
    "-f", "s16le", "-ar", String(SAMPLE_RATE), "-ac", String(channels), "-i", raw,
    "-af", "ebur128=framelog=quiet", "-f", "null", "-",
  ]);
  return parseIntegratedLoudness(stderr);
}

export async function measureLoudness(file: string): Promise<number> {
  const { stderr } = await run("ffmpeg", [
    "-hide_banner", "-nostats", "-i", file,
    "-af", "ebur128=framelog=quiet", "-f", "null", "-",
  ]);
  return parseIntegratedLoudness(stderr);
}

/**
 * Writes the voice stem: lead-in silence, each clip, the planned pauses, and the tail,
 * as one raw PCM file. Silence is generated as zeros so lengths are sample-exact.
 */
export async function assembleRaw(
  clips: string[],
  plan: { leadInSamples: number; pauseSamples: number[]; tailSamples: number },
  outRaw: string,
): Promise<void> {
  const out = fs.createWriteStream(outRaw);
  const write = async (buf: Buffer) => {
    if (!out.write(buf)) await new Promise<void>((r) => out.once("drain", () => r()));
  };
  const writeSilence = async (frames: number) => {
    const chunk = Buffer.alloc(Math.min(frames, SAMPLE_RATE * 10) * 2);
    let left = frames * 2;
    while (left > 0) {
      const n = Math.min(left, chunk.length);
      await write(n === chunk.length ? chunk : chunk.subarray(0, n));
      left -= n;
    }
  };
  await writeSilence(plan.leadInSamples);
  for (let i = 0; i < clips.length; i++) {
    // Clips are a few seconds of mono PCM each, small enough to read whole.
    await write(fs.readFileSync(clips[i]));
    if (i < plan.pauseSamples.length) await writeSilence(plan.pauseSamples[i]);
  }
  await writeSilence(plan.tailSamples);
  await new Promise<void>((resolve, reject) => {
    out.end(() => resolve());
    out.once("error", reject);
  });
}

/** Encodes a mono raw voice track to AAC with a static gain to reach VOICE_LUFS. */
export async function encodeVoice(raw: string, out: string, measuredLufs: number): Promise<void> {
  const gain = Math.max(-20, Math.min(20, VOICE_LUFS - measuredLufs));
  await run("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "s16le", "-ar", String(SAMPLE_RATE), "-ac", "1", "-i", raw,
    "-af", `highpass=f=60,volume=${gain.toFixed(2)}dB,alimiter=limit=0.89:level=false`,
    "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart", out,
  ]);
}

/**
 * Builds a smooth gain envelope that lowers the music while the voice speaks.
 * Nearby phrases are merged so the music doesn't pump between sentences.
 */
export function duckingExpression(intervals: [number, number][], ramp = 1.2, mergeGap = 3.5): string {
  if (intervals.length === 0) return "1";
  const merged: [number, number][] = [];
  for (const [s, e] of intervals) {
    const last = merged[merged.length - 1];
    if (last && s - last[1] < mergeGap) last[1] = Math.max(last[1], e);
    else merged.push([s, e]);
  }
  const terms = merged.map(([s, e]) => {
    const a = (s - ramp).toFixed(2);
    const b = (e + ramp).toFixed(2);
    // 0 outside [a,b], ramps linearly to 1 inside, over `ramp` seconds each side.
    return `clip((t-${a})/${ramp},0,1)*clip((${b}-t)/${ramp},0,1)`;
  });
  const depth = (1 - DUCK_GAIN).toFixed(3);
  return `1-${depth}*min(1,${terms.join("+")})`;
}

export interface MusicRenderOptions {
  trackFile: string;
  trackDuration: number;
  trackLufs: number;
  totalSeconds: number;
  speechIntervals: [number, number][];
  fadeIn: number;
  fadeOut: number;
  out: string;
}

/** Loops the track with crossfades to the exact length, levels it, ducks it under speech and fades it. */
export async function renderMusic(o: MusicRenderOptions): Promise<void> {
  const xfade = Math.min(8, Math.max(2, o.trackDuration / 6));
  const usable = o.trackDuration - xfade;
  const copies = Math.max(1, Math.ceil((o.totalSeconds - xfade) / usable) + 1);
  const args = ["-hide_banner", "-loglevel", "error", "-y"];
  for (let i = 0; i < copies; i++) args.push("-i", o.trackFile);

  const gain = Math.max(-30, Math.min(20, MUSIC_LUFS - o.trackLufs));
  const parts: string[] = [];
  for (let i = 0; i < copies; i++) parts.push(`[${i}:a]aformat=sample_rates=${SAMPLE_RATE}:channel_layouts=stereo[s${i}]`);
  let last = "s0";
  for (let i = 1; i < copies; i++) {
    parts.push(`[${last}][s${i}]acrossfade=d=${xfade.toFixed(2)}:c1=qsin:c2=qsin[x${i}]`);
    last = `x${i}`;
  }
  const T = o.totalSeconds.toFixed(4);
  const duck = duckingExpression(o.speechIntervals);
  parts.push(
    `[${last}]apad=whole_dur=${T},atrim=0:${T},asetpts=N/SR/TB,` +
      `volume=${gain.toFixed(2)}dB,` +
      `volume='${duck}':eval=frame,` +
      `afade=t=in:st=0:d=${o.fadeIn},afade=t=out:st=${(o.totalSeconds - o.fadeOut).toFixed(3)}:d=${o.fadeOut},` +
      `alimiter=limit=0.7:level=false[m]`,
  );
  // The graph is passed inline: -filter_complex_script was deprecated in FFmpeg 7.1 and
  // removed in 8, and even a 20-minute ducking expression is far below the argument limit.
  await run("ffmpeg", [
    ...args,
    "-filter_complex", parts.join(";"),
    "-map", "[m]", "-c:a", "aac", "-aac_coder", "fast", "-b:a", "112k", "-movflags", "+faststart", o.out,
  ]);
}

/** Normalises an uploaded or generated track into the library format (stereo AAC, 44.1 kHz). */
export async function transcodeTrack(input: string, out: string, maxSeconds = 900): Promise<void> {
  await run("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-y", "-i", input,
    "-vn", "-map_metadata", "-1", "-t", String(maxSeconds),
    "-ac", "2", "-ar", String(SAMPLE_RATE), "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", out,
  ]);
}

/** Encodes a single clip (e.g. a voice preview) to normalised AAC. */
export async function encodeClip(input: string, out: string): Promise<void> {
  const tmpRaw = `${out}.raw`;
  try {
    await decodeToRaw(input, tmpRaw, 1);
    const lufs = await measureLoudnessRaw(tmpRaw, 1);
    await encodeVoice(tmpRaw, out, lufs);
  } finally {
    fs.rmSync(tmpRaw, { force: true });
  }
}
