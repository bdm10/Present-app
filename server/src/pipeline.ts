import fs from "node:fs";
import path from "node:path";
import { DateTime } from "luxon";
import type { Config } from "./config.js";
import { DB, nowIso, type SessionRow } from "./db.js";
import { getSettings } from "./settings.js";
import { assertWithinBudget, estimateSessionUsd, recordSpend } from "./spend.js";
import { getSessionRow, sessionDir, setStatus } from "./sessions.js";
import type { Providers } from "./providers/index.js";
import type { MeditationScript, RecentSessionNote, ScriptRequest } from "./providers/types.js";
import { WORD_BUDGET, cleanSpokenText, countWords, displayText } from "./providers/script/prompt.js";
import { SAMPLE_RATE, assembleRaw, decodeToRaw, encodeVoice, measureLoudnessRaw, probeDuration, renderMusic } from "./audio/ffmpeg.js";
import { SpeechTooLongError, framingFor, planTiming } from "./audio/timing.js";
import { markTrackUsed, pickTrack } from "./music.js";

export interface PipelineContext {
  cfg: Config;
  db: DB;
  providers: Providers;
  log: { info: (o: object, msg?: string) => void; warn: (o: object, msg?: string) => void };
}

/** A failure the user should see as-is (vs. an internal error, which gets a gentle generic message). */
export class UserFacingError extends Error {
  constructor(message: string, readonly retryable = true) {
    super(message);
  }
}

function describeWhen(row: SessionRow, timeZone: string, dailyTime: string): string {
  const now = DateTime.now().setZone(timeZone);
  const hour = row.kind === "daily" ? Number(dailyTime.slice(0, 2)) : now.hour;
  const part = hour < 5 ? "night" : hour < 12 ? "morning" : hour < 17 ? "afternoon" : hour < 21 ? "evening" : "night";
  const date = DateTime.fromISO(row.local_date, { zone: timeZone });
  return `${date.toFormat("cccc")} ${part}, ${date.toFormat("d LLLL")}`;
}

function recentNotes(db: DB, excludeId: string): RecentSessionNote[] {
  const rows = db
    .prepare("SELECT title, theme, script FROM sessions WHERE id != ? AND script IS NOT NULL ORDER BY created_at DESC LIMIT 8")
    .all(excludeId) as { title: string; theme: string; script: string }[];
  return rows.map((r) => {
    const s = JSON.parse(r.script) as MeditationScript;
    return { title: r.title, theme: r.theme, motifs: s.motifs ?? [], opening: displayText(s.segments[0]?.text ?? "") };
  });
}

/** Rough speech length before paying for narration: ~2.3 words per second at a meditative pace. */
function estimatedSpeechSeconds(script: MeditationScript): number {
  return countWords(script.segments.map((s) => s.text)) / 2.3;
}

export async function generateSession(ctx: PipelineContext, sessionId: string): Promise<void> {
  const { cfg, db, providers, log } = ctx;
  const row = getSessionRow(db, sessionId);
  if (!row) throw new UserFacingError("Session no longer exists", false);
  const settings = getSettings(db, providers.voice.defaultVoiceId());
  const voice = providers.voice;
  const scriptProvider = providers.script;

  const estimate = estimateSessionUsd(cfg, row.duration_minutes, scriptProvider.mode === "live", voice.mode === "live");
  try {
    assertWithinBudget(cfg, db, settings.timeZone, estimate);
  } catch (err) {
    throw new UserFacingError((err as Error).message, false);
  }

  // Resolve the voice once so a missing/removed voice fails early, before spending anything.
  const voices = await voice.listVoices();
  const voiceInfo = voices.find((v) => v.id === settings.voiceId) ?? voices.find((v) => v.id === voice.defaultVoiceId()) ?? voices[0];
  if (!voiceInfo) throw new UserFacingError("No narration voice is available. Check ELEVENLABS_VOICE_IDS on the server.", false);

  const dir = sessionDir(cfg.dataDir, sessionId);
  const work = path.join(dir, "work");
  fs.rmSync(work, { recursive: true, force: true });
  fs.mkdirSync(work, { recursive: true });

  const framing = framingFor(row.duration_minutes, row.theme);
  const targetSeconds = row.duration_minutes * 60;
  let totalCost = 0;
  let feedback: string | undefined;

  for (let round = 0; round < 3; round++) {
    // 1. Script
    setStatus(db, sessionId, "generating", "Writing the script");
    const req: ScriptRequest = {
      theme: row.theme,
      durationMinutes: row.duration_minutes,
      kind: row.kind,
      when: describeWhen(row, settings.timeZone, settings.dailyTime),
      profile: settings.profile,
      recent: recentNotes(db, sessionId),
      allowAudioTags: voice.supportsAudioTags,
      feedback,
    };
    const written = await scriptProvider.write(req);
    totalCost += written.costUsd;
    recordSpend(db, scriptProvider.name, written.usage?.outputTokens ?? 0, written.costUsd, sessionId, `script ${written.model}`);

    const script = written.script;
    script.segments = script.segments
      .map((s) => ({ text: cleanSpokenText(s.text, voice.supportsAudioTags), pauseAfterSeconds: Number(s.pauseAfterSeconds) || 3 }))
      .filter((s) => displayText(s.text).length > 0);
    if (script.segments.length < 4) {
      feedback = "The previous script had too few segments. Write the full meditation as many short segments.";
      continue;
    }
    const words = countWords(script.segments.map((s) => s.text));
    const [minW, maxW] = WORD_BUDGET[row.duration_minutes];
    const speechBudget = targetSeconds - framing.leadIn - framing.tail - 1.2 * (script.segments.length - 1);
    if (scriptProvider.mode === "live" && (words > maxW * 1.25 || estimatedSpeechSeconds(script) > speechBudget * 0.95)) {
      feedback = `The previous script had ${words} words; this session allows at most ${maxW}. Write a shorter script with more silence.`;
      continue;
    }
    if (scriptProvider.mode === "live" && words < minW * 0.6) {
      feedback = `The previous script had only ${words} words; aim for ${minW} to ${maxW}.`;
      continue;
    }

    // 2. Narration, one segment at a time so each pause can be placed precisely.
    const clips: string[] = [];
    const samples: number[] = [];
    const requestIds: string[] = [];
    let chars = 0;
    let ttsCost = 0;
    for (let i = 0; i < script.segments.length; i++) {
      setStatus(db, sessionId, "generating", `Recording the voice (${i + 1} of ${script.segments.length})`);
      const result = await voice.synthesize({
        voiceId: voiceInfo.id,
        text: script.segments[i].text,
        previousText: script.segments[i - 1]?.text,
        nextText: script.segments[i + 1]?.text,
        previousRequestIds: voice.supportsRequestStitching ? requestIds.slice(-3) : undefined,
      });
      if (result.requestId) requestIds.push(result.requestId);
      chars += result.chars;
      ttsCost += result.costUsd;
      const raw = path.join(work, `clip-${String(i).padStart(3, "0")}.raw`);
      samples.push(await decodeToRaw(result.file, raw, 1));
      clips.push(raw);
    }
    totalCost += ttsCost;
    recordSpend(db, voice.name, chars, ttsCost, sessionId, `tts ${voice.model}`);

    // 3. Timing: fit the silences so the session is exactly the chosen length.
    let plan;
    try {
      plan = planTiming({
        sampleRate: SAMPLE_RATE,
        targetSeconds,
        speechSamples: samples,
        pauseHints: script.segments.map((s) => s.pauseAfterSeconds),
        leadInSeconds: framing.leadIn,
        tailSeconds: framing.tail,
        maxPauseSeconds: row.duration_minutes >= 15 ? 90 : 60,
      });
    } catch (err) {
      if (err instanceof SpeechTooLongError && scriptProvider.mode === "live" && round < 2) {
        const cut = Math.ceil(err.overSeconds * 2.3 + 30);
        feedback = `The spoken part ran ${Math.ceil(err.overSeconds)} seconds too long. Use about ${cut} fewer words and keep more silence.`;
        log.warn({ sessionId, over: err.overSeconds }, "script too long, retrying");
        continue;
      }
      throw err;
    }

    // 4. Voice stem
    setStatus(db, sessionId, "generating", "Balancing the voice");
    const speechOnly = path.join(work, "speech-only.raw");
    fs.writeFileSync(speechOnly, Buffer.concat(clips.map((c) => fs.readFileSync(c))));
    const voiceLufs = await measureLoudnessRaw(speechOnly, 1);
    const voiceRaw = path.join(work, "voice.raw");
    await assembleRaw(clips, plan, voiceRaw);
    const voiceOut = path.join(dir, "voice.m4a");
    await encodeVoice(voiceRaw, voiceOut, voiceLufs);

    // 5. Music stem
    setStatus(db, sessionId, "generating", "Adding the music");
    const track = pickTrack(db, settings.musicTrackId, row.theme);
    const musicOut = path.join(dir, "music.m4a");
    await renderMusic({
      trackFile: track.file,
      trackDuration: track.duration_seconds,
      trackLufs: track.loudness_lufs ?? -20,
      totalSeconds: targetSeconds,
      speechIntervals: plan.speechIntervals,
      fadeIn: Math.min(8, framing.leadIn),
      fadeOut: framing.fadeOut,
      out: musicOut,
    });
    markTrackUsed(db, track.id);

    // 6. Verify before telling anyone it's ready.
    const [vd, md] = await Promise.all([probeDuration(voiceOut), probeDuration(musicOut)]);
    if (Math.abs(vd - targetSeconds) > 0.25 || Math.abs(md - targetSeconds) > 0.25) {
      throw new Error(`Stem length mismatch: voice ${vd.toFixed(2)}s, music ${md.toFixed(2)}s, target ${targetSeconds}s`);
    }

    const transcript = script.segments.map((s, i) => ({
      text: displayText(s.text),
      startSeconds: Math.round(plan.speechStartSeconds[i] * 10) / 10,
    }));
    const demo = scriptProvider.mode === "demo" || voice.mode === "demo";
    const providersJson = {
      script: scriptProvider.mode === "live" ? `anthropic:${written.model}` : "demo:prewritten",
      voice: voice.mode === "live" ? `elevenlabs:${voice.model}:${voiceInfo.id}` : `demo:piper:${voiceInfo.id}`,
      music: track.id,
    };
    db.prepare(
      `UPDATE sessions SET status = 'ready', status_detail = NULL, error = NULL, title = ?, summary = ?, reflection_question = ?,
         duration_seconds = ?, demo = ?, providers = ?, voice_name = ?, music_title = ?, music_track_id = ?,
         voice_bytes = ?, music_bytes = ?, transcript = ?, script = ?, ready_at = ?, cost_usd = cost_usd + ?
       WHERE id = ?`,
    ).run(
      script.title.trim().slice(0, 80),
      script.summary.trim().slice(0, 240),
      script.reflectionQuestion.trim().slice(0, 300),
      targetSeconds,
      demo ? 1 : 0,
      JSON.stringify(providersJson),
      voiceInfo.name,
      track.title,
      track.id,
      fs.statSync(voiceOut).size,
      fs.statSync(musicOut).size,
      JSON.stringify(transcript),
      JSON.stringify(script),
      nowIso(),
      totalCost,
      sessionId,
    );
    fs.rmSync(work, { recursive: true, force: true });
    log.info({ sessionId, words: countWords(script.segments.map((s) => s.text)), costUsd: totalCost }, "session ready");
    return;
  }
  fs.rmSync(work, { recursive: true, force: true });
  throw new UserFacingError("The script didn't fit the chosen length after several tries.");
}
