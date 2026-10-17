import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { generateSession } from "../src/pipeline.js";
import { createSessionWithJob, getSessionRow, sessionDir } from "../src/sessions.js";
import { DEMO_SCRIPTS } from "../src/providers/script/demo-scripts.js";
import { DemoVoiceProvider } from "../src/providers/voice/demo.js";
import { cleanSpokenText } from "../src/providers/script/prompt.js";
import { SAMPLE_RATE, decodeToRaw, measureLoudness, probeDuration, renderMusic, run } from "../src/audio/ffmpeg.js";
import { framingFor, planTiming } from "../src/audio/timing.js";
import { DURATIONS, type Duration, type Theme } from "../src/db.js";
import { tempDir, testEnv } from "./helpers.js";

async function rmsDb(file: string, start: number, dur: number): Promise<number> {
  const { stderr } = await run("ffmpeg", ["-hide_banner", "-ss", String(start), "-t", String(dur), "-i", file, "-af", "astats=metadata=0", "-f", "null", "-"]);
  const m = stderr.match(/Overall[\s\S]*?RMS level dB:\s*(-?[\d.]+|-inf)/);
  return m && m[1] !== "-inf" ? Number(m[1]) : -120;
}

describe("demo assets", () => {
  it("every demo line has a pre-rendered clip for every demo voice", async () => {
    const voice = new DemoVoiceProvider();
    const voices = await voice.listVoices();
    expect(voices.length).toBeGreaterThanOrEqual(2);
    for (const v of voices) {
      expect(fs.existsSync(path.join(path.dirname(voice.clipPath(v.id, "x")), "preview.m4a"))).toBe(true);
      for (const s of DEMO_SCRIPTS) for (const l of s.lines) expect(fs.existsSync(voice.clipPath(v.id, cleanSpokenText(l.t, false))), l.t).toBe(true);
    }
  });

  it("every demo script fits every duration", async () => {
    const voice = new DemoVoiceProvider();
    const tmp = tempDir();
    const cache = new Map<string, number>();
    for (const script of DEMO_SCRIPTS) {
      for (const d of DURATIONS) {
        const lines = script.lines.filter((l) => d > 5 || !l.ext);
        const samples: number[] = [];
        for (const l of lines) {
          const file = voice.clipPath("demo-wren", cleanSpokenText(l.t, false));
          if (!cache.has(file)) cache.set(file, await decodeToRaw(file, path.join(tmp, "c.raw")));
          samples.push(cache.get(file)!);
        }
        const f = framingFor(d, script.theme);
        expect(() =>
          planTiming({ sampleRate: SAMPLE_RATE, targetSeconds: d * 60, speechSamples: samples, pauseHints: lines.map((l) => l.p), leadInSeconds: f.leadIn, tailSeconds: f.tail }),
        ).not.toThrow();
      }
    }
  });
});

describe("generateSession (demo providers, real audio)", () => {
  const cases: [Theme, Duration][] = [
    ["presence", 5],
    ["family", 10],
    ["sleep", 15],
    ["letting-go-of-work", 20],
  ];
  for (const [theme, minutes] of cases) {
    it(`renders a ${minutes}-minute ${theme} session with exactly matching stems`, { timeout: 400_000 }, async () => {
      const env = testEnv();
      const row = createSessionWithJob(env.db, { kind: "on_demand", localDate: "2026-10-17", theme, durationMinutes: minutes })!;
      await generateSession(env.ctx, row.id);
      const done = getSessionRow(env.db, row.id)!;
      expect(done.status).toBe("ready");
      expect(done.demo).toBe(1);
      expect(done.title).toBeTruthy();
      expect(done.reflection_question).toMatch(/\?$/);
      const dir = sessionDir(env.cfg.dataDir, row.id);
      const voice = path.join(dir, "voice.m4a");
      const music = path.join(dir, "music.m4a");
      expect(Math.abs((await probeDuration(voice)) - minutes * 60)).toBeLessThan(0.1);
      expect(Math.abs((await probeDuration(music)) - minutes * 60)).toBeLessThan(0.1);
      expect(fs.existsSync(path.join(dir, "work"))).toBe(false);
      expect(done.voice_bytes).toBe(fs.statSync(voice).size);

      // Loudness targets: clear voice, music underneath.
      const voiceLufs = await measureLoudness(voice);
      const musicLufs = await measureLoudness(music);
      expect(voiceLufs).toBeGreaterThan(-21);
      expect(voiceLufs).toBeLessThan(-17);
      expect(musicLufs).toBeLessThan(voiceLufs - 5);

      // Silence really dominates: speech is well under the whole duration.
      const transcript = JSON.parse(done.transcript!) as { text: string; startSeconds: number }[];
      expect(transcript.length).toBeGreaterThan(10);
      expect(transcript[0].startSeconds).toBeGreaterThanOrEqual(5);

      // Ducking: music is quieter while the voice speaks than in the middle of a long pause.
      const script = JSON.parse(done.script!) as { segments: { text: string; pauseAfterSeconds: number }[] };
      const idx = script.segments
        .map((s, i) => ({ i, len: s.text.length, pause: s.pauseAfterSeconds }))
        .filter((s) => s.pause >= 15 && s.len > 60 && s.i + 1 < transcript.length)
        .sort((a, b) => b.len - a.len)[0].i;
      const speakAt = transcript[idx].startSeconds + 0.6;
      const pauseMid = (transcript[idx].startSeconds + transcript[idx + 1].startSeconds) / 2 + 4;
      // Compare against the same music rendered without ducking, so the track's own swells don't matter.
      const track = env.db.prepare("SELECT * FROM music_tracks WHERE id = ?").get(done.music_track_id!) as {
        file: string; duration_seconds: number; loudness_lufs: number;
      };
      const reference = path.join(tempDir(), "ref.m4a");
      const f = framingFor(minutes, theme);
      await renderMusic({ trackFile: track.file, trackDuration: track.duration_seconds, trackLufs: track.loudness_lufs, totalSeconds: minutes * 60,
        speechIntervals: [], fadeIn: Math.min(8, f.leadIn), fadeOut: f.fadeOut, out: reference });
      const duckedBy = (await rmsDb(reference, speakAt, 1.5)) - (await rmsDb(music, speakAt, 1.5));
      const pauseDiff = (await rmsDb(reference, pauseMid, 1.5)) - (await rmsDb(music, pauseMid, 1.5));
      expect(duckedBy).toBeGreaterThan(5);
      expect(duckedBy).toBeLessThan(9);
      expect(Math.abs(pauseDiff)).toBeLessThan(1);
      const between = await rmsDb(music, pauseMid, 1.5);

      // Fades: silent-ish at the very start and very end.
      expect(await rmsDb(music, 0, 0.3)).toBeLessThan(between - 15);
      expect(await rmsDb(music, minutes * 60 - 0.4, 0.3)).toBeLessThan(between - 15);
    });
  }

  it("avoids music on the 'sleep' mood for daytime themes", async () => {
    const env = testEnv();
    const row = createSessionWithJob(env.db, { kind: "on_demand", localDate: "2026-10-17", theme: "gratitude", durationMinutes: 5 })!;
    await generateSession(env.ctx, row.id);
    expect(getSessionRow(env.db, row.id)!.music_track_id).not.toBe("builtin-low-tide");
  });
});
