/**
 * Exercises the real Anthropic and ElevenLabs code paths against local fake servers.
 * These are mocks: they verify request shapes and the end-to-end wiring, not the
 * real services (which need credentials).
 */
import fs from "node:fs";
import path from "node:path";
import Fastify, { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { generateSession } from "../src/pipeline.js";
import { createSessionWithJob, getSessionRow } from "../src/sessions.js";
import { run } from "../src/audio/ffmpeg.js";
import { monthSpendUsd } from "../src/spend.js";
import { JobRunner } from "../src/jobs.js";
import { tempDir, testEnv } from "./helpers.js";

interface Captured {
  anthropic: { headers: Record<string, unknown>; body: Record<string, unknown> }[];
  tts: { voice: string; headers: Record<string, unknown>; body: Record<string, unknown> }[];
}

const captured: Captured = { anthropic: [], tts: [] };
let anthropicReplies: object[] = [];
let fake: FastifyInstance;
let baseUrl = "";
const clipDir = tempDir();

function scriptWithWords(words: number, segments = 20) {
  const per = Math.max(3, Math.round(words / segments));
  return {
    title: "Morning Light",
    summary: "A short test session.",
    reflectionQuestion: "What did you notice?",
    motifs: ["test light"],
    segments: Array.from({ length: segments }, (_, i) => ({
      text: (i % 5 === 0 ? "[softly] " : "") + Array.from({ length: per }, (_, w) => (w === 0 ? `Notice ${i}` : "slowly")).join(" ") + ".",
      pauseAfterSeconds: i % 4 === 3 ? 25 : 5,
    })),
  };
}

function message(content: object) {
  return {
    id: "msg_fake",
    type: "message",
    role: "assistant",
    model: "claude-opus-5-5",
    content: [{ type: "text", text: JSON.stringify(content) }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: 3000, output_tokens: 2500, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
  };
}

async function clipFor(seconds: number): Promise<Buffer> {
  const file = path.join(clipDir, `${seconds.toFixed(1)}.mp3`);
  if (!fs.existsSync(file)) {
    await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", `sine=frequency=180:duration=${seconds.toFixed(1)}`, "-af", "volume=0.3", "-ar", "44100", file]);
  }
  return fs.readFileSync(file);
}

beforeAll(async () => {
  fake = Fastify();
  fake.post("/v1/messages", async (req) => {
    captured.anthropic.push({ headers: req.headers, body: req.body as Record<string, unknown> });
    return message(anthropicReplies.shift() ?? scriptWithWords(240));
  });
  fake.get("/v2/voices", async () => ({
    voices: [
      { voice_id: "voiceCalm01", name: "Calm Narrator", labels: { descriptive: "calm", accent: "british", gender: "female" } },
      { voice_id: "voiceDeep02", name: "Deep Voice", labels: { accent: "american" } },
    ],
    has_more: false,
  }));
  fake.post("/v1/text-to-speech/:voice", async (req, reply) => {
    const body = req.body as { text: string };
    captured.tts.push({ voice: (req.params as { voice: string }).voice, headers: req.headers, body: req.body as Record<string, unknown> });
    const seconds = Math.max(1, body.text.split(/\s+/).length / 2.4);
    reply.header("request-id", `req_${captured.tts.length}`).header("content-type", "audio/mpeg");
    return clipFor(seconds);
  });
  await fake.listen({ port: 0, host: "127.0.0.1" });
  const addr = fake.server.address() as { port: number };
  baseUrl = `http://127.0.0.1:${addr.port}`;
});

afterAll(async () => {
  await fake.close();
});

function liveEnv(extra: Record<string, string> = {}) {
  return testEnv({
    FORCE_DEMO: "false",
    ANTHROPIC_API_KEY: "sk-ant-test",
    PRESENT_ANTHROPIC_BASE_URL: baseUrl,
    ELEVENLABS_API_KEY: "xi-test",
    PRESENT_ELEVENLABS_BASE_URL: baseUrl,
    ...extra,
  });
}

describe("live providers (against local fakes)", () => {
  it("writes with Claude, narrates with ElevenLabs v4 and records spend", { timeout: 120_000 }, async () => {
    captured.anthropic.length = 0;
    captured.tts.length = 0;
    const env = liveEnv();
    expect(env.providers.script.mode).toBe("live");
    expect(env.providers.voice.mode).toBe("live");
    const row = createSessionWithJob(env.db, { kind: "daily", localDate: "2026-10-17", theme: "family", durationMinutes: 5 })!;
    await generateSession(env.ctx, row.id);
    const done = getSessionRow(env.db, row.id)!;
    expect(done.status).toBe("ready");
    expect(done.demo).toBe(0);
    expect(JSON.parse(done.providers!)).toMatchObject({ script: "anthropic:claude-opus-5-5", voice: "elevenlabs:eleven_v4:voiceCalm01" });
    expect(done.voice_name).toBe("Calm Narrator");

    // Claude request shape
    const a = captured.anthropic[0];
    expect(a.headers["x-api-key"]).toBe("sk-ant-test");
    expect(String(a.headers["anthropic-beta"])).toContain("server-side-fallback-2026-07-01");
    expect(a.body.model).toBe("claude-opus-5-5");
    expect(a.body.fallbacks).toBe("default");
    expect(a.body).not.toHaveProperty("thinking");
    const oc = a.body.output_config as { effort: string; format: { type: string } };
    expect(oc.effort).toBe("medium");
    expect(oc.format.type).toBe("json_schema");
    const userText = JSON.stringify(a.body.messages);
    expect(userText).toContain("family");
    expect(userText).toContain("delivery cues"); // v4 supports audio tags

    // ElevenLabs request shape
    expect(captured.tts.length).toBe(20);
    const t0 = captured.tts[0];
    expect(t0.voice).toBe("voiceCalm01");
    expect(t0.headers["xi-api-key"]).toBe("xi-test");
    expect(t0.body.model_id).toBe("eleven_v4");
    expect(t0.body.voice_settings).toEqual({ stability: 0.65, similarity_boost: 0.8 });
    expect(String(t0.body.text)).toMatch(/^\[softly\]/); // tags kept for v4
    expect(t0.body).not.toHaveProperty("previous_request_ids");
    expect(captured.tts[3].body.previous_request_ids).toEqual(["req_1", "req_2", "req_3"]);
    expect(captured.tts[3].body).not.toHaveProperty("previous_text");

    // Tags never reach the transcript
    const transcript = JSON.parse(done.transcript!) as { text: string }[];
    expect(transcript.every((t) => !t.text.includes("["))).toBe(true);

    // Spend: Claude (3000 in * $4 + 2500 out * $20 per M) + ElevenLabs chars * $0.08/1k
    const chars = captured.tts.reduce((n, t) => n + String(t.body.text).length, 0);
    const expected = (3000 / 1e6) * 4 + (2500 / 1e6) * 20 + (chars / 1000) * 0.08;
    expect(monthSpendUsd(env.db, "UTC")).toBeCloseTo(expected, 3);
  });

  it("re-asks Claude for a shorter script when the first one is too long, before paying for narration", { timeout: 120_000 }, async () => {
    captured.anthropic.length = 0;
    captured.tts.length = 0;
    anthropicReplies = [scriptWithWords(900, 30), scriptWithWords(240)];
    const env = liveEnv();
    const row = createSessionWithJob(env.db, { kind: "on_demand", localDate: "2026-10-17", theme: "presence", durationMinutes: 5 })!;
    await generateSession(env.ctx, row.id);
    expect(getSessionRow(env.db, row.id)!.status).toBe("ready");
    expect(captured.anthropic.length).toBe(2);
    expect(JSON.stringify(captured.anthropic[1].body.messages)).toMatch(/at most 280/);
    expect(captured.tts.length).toBe(20); // only the accepted script was narrated
  });

  it("refuses to start when the monthly spending limit would be exceeded", async () => {
    captured.anthropic.length = 0;
    captured.tts.length = 0;
    const env = liveEnv({ MONTHLY_SPEND_LIMIT_USD: "0.05" });
    const row = createSessionWithJob(env.db, { kind: "on_demand", localDate: "2026-10-17", theme: "presence", durationMinutes: 20 })!;
    const runner = new JobRunner(env.ctx);
    await runner.drain();
    const failed = getSessionRow(env.db, row.id)!;
    expect(failed.status).toBe("failed");
    expect(failed.error).toMatch(/spending limit/);
    expect(captured.anthropic.length).toBe(0);
    expect(captured.tts.length).toBe(0);
  });

  it("reuses cached narration when a failed job is retried", { timeout: 120_000 }, async () => {
    captured.tts.length = 0;
    const env = liveEnv();
    const row = createSessionWithJob(env.db, { kind: "on_demand", localDate: "2026-10-17", theme: "presence", durationMinutes: 5 })!;
    anthropicReplies = [scriptWithWords(240)];
    await generateSession(env.ctx, row.id);
    const first = captured.tts.length;
    anthropicReplies = [scriptWithWords(240)];
    const row2 = createSessionWithJob(env.db, { kind: "on_demand", localDate: "2026-10-17", theme: "presence", durationMinutes: 5 })!;
    await generateSession(env.ctx, row2.id);
    expect(first).toBe(20);
    expect(captured.tts.length).toBe(20); // identical text: served from the TTS cache
  });

  it("uses demo scripts if only the Anthropic key is set (the demo voice can't read new scripts)", () => {
    const env = testEnv({ FORCE_DEMO: "false", ANTHROPIC_API_KEY: "sk-ant-test" });
    expect(env.providers.script.mode).toBe("demo");
    expect(env.providers.note).toMatch(/ELEVENLABS_API_KEY/);
  });
});
