import fs from "node:fs";
import path from "node:path";
import { DateTime } from "luxon";
import { beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { JobRunner } from "../src/jobs.js";
import { Scheduler } from "../src/scheduler.js";
import { MemoryNotifier } from "../src/push/apns.js";
import { run } from "../src/audio/ffmpeg.js";
import { TOKEN, tempDir, testEnv } from "./helpers.js";

const auth = { authorization: `Bearer ${TOKEN}` };

async function makeApp(extra: Record<string, string> = {}, clock?: () => DateTime) {
  const env = testEnv(extra);
  const runner = new JobRunner(env.ctx);
  const notifier = new MemoryNotifier();
  const scheduler = new Scheduler(env.cfg, env.db, runner, notifier, () => env.providers.voice.defaultVoiceId(), clock);
  const app = await buildApp({ ...env, runner, scheduler, notifier });
  return { ...env, app, runner, scheduler, notifier };
}

function multipart(fields: Record<string, string>, file: { name: string; data: Buffer; type: string }) {
  const boundary = "----present" + Math.random().toString(16).slice(2);
  const parts: Buffer[] = [];
  for (const [k, v] of Object.entries(fields)) {
    parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`));
  }
  parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${file.name}"\r\nContent-Type: ${file.type}\r\n\r\n`));
  parts.push(file.data, Buffer.from(`\r\n--${boundary}--\r\n`));
  return { body: Buffer.concat(parts), headers: { ...auth, "content-type": `multipart/form-data; boundary=${boundary}` } };
}

describe("auth", () => {
  let app: FastifyInstance;
  beforeAll(async () => ({ app } = await makeApp()));

  it("health is public", async () => {
    expect((await app.inject({ url: "/health" })).json()).toEqual({ ok: true });
  });
  it("rejects missing and wrong tokens", async () => {
    expect((await app.inject({ url: "/api/status" })).statusCode).toBe(401);
    expect((await app.inject({ url: "/api/status", headers: { authorization: "Bearer nope-nope-nope-nope" } })).statusCode).toBe(401);
    expect((await app.inject({ url: "/api/sessions/ses_abcdefgh/audio/voice.m4a" })).statusCode).toBe(401);
  });
  it("accepts the right token and reports demo mode honestly", async () => {
    const res = await app.inject({ url: "/api/status", headers: auth });
    expect(res.statusCode).toBe(200);
    const s = res.json();
    expect(s.providers.script.mode).toBe("demo");
    expect(s.providers.voice.mode).toBe("demo");
    expect(s.providers.voice.detail).toMatch(/not|Demo/i);
    expect(s.spend.monthLimitUsd).toBe(15);
  });
});

describe("settings", () => {
  let app: FastifyInstance;
  beforeAll(async () => ({ app } = await makeApp()));

  it("returns defaults and merges partial updates", async () => {
    const def = (await app.inject({ url: "/api/settings", headers: auth })).json();
    expect(def.dailyTime).toBe("07:00");
    expect(def.voiceId).toBe("demo-wren");
    const res = await app.inject({
      method: "PUT",
      url: "/api/settings",
      headers: auth,
      payload: { timeZone: "Europe/London", dailyTime: "06:15", defaultDurationMinutes: 15, profile: { name: "Brian" } },
    });
    expect(res.statusCode).toBe(200);
    const s = res.json();
    expect(s).toMatchObject({ timeZone: "Europe/London", dailyTime: "06:15", defaultDurationMinutes: 15 });
    expect(s.profile).toEqual({ name: "Brian", lovedOnes: "", context: "" });
    const s2 = (await app.inject({ method: "PUT", url: "/api/settings", headers: auth, payload: { profile: { lovedOnes: "Ana and the kids" } } })).json();
    expect(s2.profile).toEqual({ name: "Brian", lovedOnes: "Ana and the kids", context: "" });
  });

  it("validates input", async () => {
    const bad = async (payload: object) => (await app.inject({ method: "PUT", url: "/api/settings", headers: auth, payload })).statusCode;
    expect(await bad({ timeZone: "Mars/Olympus" })).toBe(400);
    expect(await bad({ dailyTime: "7am" })).toBe(400);
    expect(await bad({ defaultDurationMinutes: 12 })).toBe(400);
    expect(await bad({ themes: [] })).toBe(400);
    expect(await bad({ themes: ["sleep", "nonsense"] })).toBe(400);
    expect(await bad({ voiceId: "not-a-voice" })).toBe(400);
    expect(await bad({ musicTrackId: "nope" })).toBe(400);
    expect(await bad({ surprise: true })).toBe(400);
  });
});

describe("voices and music", () => {
  let app: FastifyInstance;
  beforeAll(async () => ({ app } = await makeApp()));

  it("lists demo voices with playable previews (with Range support)", async () => {
    const { voices } = (await app.inject({ url: "/api/voices", headers: auth })).json();
    expect(voices.length).toBe(2);
    expect(voices[0].provider).toBe("demo");
    const full = await app.inject({ url: voices[0].previewUrl, headers: auth });
    expect(full.statusCode).toBe(200);
    expect(full.headers["content-type"]).toBe("audio/mp4");
    const part = await app.inject({ url: voices[0].previewUrl, headers: { ...auth, range: "bytes=0-99" } });
    expect(part.statusCode).toBe(206);
    expect(part.rawPayload.length).toBe(100);
    expect(part.headers["content-range"]).toMatch(/^bytes 0-99\//);
  });

  it("lists built-in tracks, uploads a Suno-style track, toggles and deletes it", async () => {
    const { tracks } = (await app.inject({ url: "/api/music", headers: auth })).json();
    expect(tracks.map((t: { source: string }) => t.source)).toEqual(["builtin", "builtin", "builtin"]);
    expect(tracks[0].license).toMatch(/CC0/);

    const wav = path.join(tempDir(), "track.wav");
    await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=220:duration=30", wav]);
    const mp = multipart({ title: "My Suno Track" }, { name: "suno.wav", data: fs.readFileSync(wav), type: "audio/wav" });
    const up = await app.inject({ method: "POST", url: "/api/music", payload: mp.body, headers: mp.headers });
    expect(up.statusCode).toBe(201);
    const track = up.json();
    expect(track).toMatchObject({ title: "My Suno Track", source: "upload", enabled: true, durationSeconds: 30 });

    const off = await app.inject({ method: "PATCH", url: `/api/music/${track.id}`, headers: auth, payload: { enabled: false } });
    expect(off.json().enabled).toBe(false);
    expect((await app.inject({ url: track.previewUrl, headers: auth })).statusCode).toBe(200);
    expect((await app.inject({ method: "DELETE", url: `/api/music/${tracks[0].id}`, headers: auth })).statusCode).toBe(400);
    expect((await app.inject({ method: "DELETE", url: `/api/music/${track.id}`, headers: auth })).statusCode).toBe(204);
    expect((await app.inject({ url: "/api/music", headers: auth })).json().tracks).toHaveLength(3);
  });

  it("rejects files that aren't audio", async () => {
    const mp = multipart({}, { name: "notes.txt", data: Buffer.from("hello"), type: "text/plain" });
    const res = await app.inject({ method: "POST", url: "/api/music", payload: mp.body, headers: mp.headers });
    expect(res.statusCode).toBe(400);
  });
});

describe("sessions", () => {
  it("creates an on-demand session, plays its audio, favourites it and deletes it", { timeout: 200_000 }, async () => {
    const { app, runner } = await makeApp();
    const created = await app.inject({ method: "POST", url: "/api/sessions", headers: auth, payload: { theme: "gratitude", durationMinutes: 5 } });
    expect(created.statusCode).toBe(202);
    const s0 = created.json();
    expect(s0.status).toBe("queued");
    expect(s0.audio).toBeNull();

    await runner.drain();
    const s = (await app.inject({ url: `/api/sessions/${s0.id}`, headers: auth })).json();
    expect(s).toMatchObject({ status: "ready", theme: "gratitude", durationMinutes: 5, durationSeconds: 300, demo: true, favorite: false });
    expect(s.title).toBe("Small, Ordinary Things");
    expect(s.providers.voice).toMatch(/^demo:/);
    expect(s.transcript.length).toBeGreaterThan(5);

    const voice = await app.inject({ url: s.audio.voiceUrl, headers: auth });
    expect(voice.statusCode).toBe(200);
    expect(voice.rawPayload.length).toBe(s.audio.voiceBytes);
    const music = await app.inject({ url: s.audio.musicUrl, headers: { ...auth, range: "bytes=100-" } });
    expect(music.statusCode).toBe(206);
    expect(music.rawPayload.length).toBe(s.audio.musicBytes - 100);
    expect((await app.inject({ url: `/api/sessions/${s.id}/audio/../../etc/passwd`, headers: auth })).statusCode).toBe(404);

    const fav = await app.inject({ method: "PATCH", url: `/api/sessions/${s.id}`, headers: auth, payload: { favorite: true } });
    expect(fav.json().favorite).toBe(true);
    const favs = (await app.inject({ url: "/api/sessions?favorites=true", headers: auth })).json().sessions;
    expect(favs.map((x: { id: string }) => x.id)).toEqual([s.id]);

    expect((await app.inject({ method: "DELETE", url: `/api/sessions/${s.id}`, headers: auth })).statusCode).toBe(204);
    expect((await app.inject({ url: `/api/sessions/${s.id}`, headers: auth })).statusCode).toBe(404);
    expect((await app.inject({ url: s.audio.voiceUrl, headers: auth })).statusCode).toBe(404);
  });

  it("validates new-session input and enforces the daily on-demand limit", async () => {
    const { app } = await makeApp({ DAILY_ON_DEMAND_LIMIT: "1" });
    expect((await app.inject({ method: "POST", url: "/api/sessions", headers: auth, payload: { durationMinutes: 7 } })).statusCode).toBe(400);
    expect((await app.inject({ method: "POST", url: "/api/sessions", headers: auth, payload: { theme: "joy" } })).statusCode).toBe(400);
    expect((await app.inject({ method: "POST", url: "/api/sessions", headers: auth, payload: {} })).statusCode).toBe(202);
    const second = await app.inject({ method: "POST", url: "/api/sessions", headers: auth, payload: {} });
    expect(second.statusCode).toBe(402);
    expect(second.json().error.code).toBe("spend_limit");
  });

  it("shows today's daily session once the scheduler has created it", async () => {
    const now = DateTime.utc();
    const { app, scheduler } = await makeApp({}, () => now);
    const local = now.setZone("UTC");
    // Set the daily time to a few minutes from now so we're inside the generation window.
    const ready = local.plus({ minutes: 10 });
    await app.inject({
      method: "PUT",
      url: "/api/settings",
      headers: auth,
      payload: { timeZone: "UTC", dailyTime: ready.toFormat("HH:mm") },
    });
    const before = (await app.inject({ url: "/api/today", headers: auth })).json();
    expect(before.session).toBeNull();
    if (ready.toISODate() !== local.toISODate()) return; // too close to midnight to test meaningfully
    await scheduler.tick();
    const after = (await app.inject({ url: "/api/today", headers: auth })).json();
    expect(after.session.kind).toBe("daily");
    expect(["queued", "generating", "ready"]).toContain(after.session.status);
  });

  it("rejects malformed ids", async () => {
    const { app } = await makeApp();
    expect((await app.inject({ url: "/api/sessions/../../x", headers: auth })).statusCode).toBeGreaterThanOrEqual(400);
    expect((await app.inject({ url: "/api/sessions/not-a-session", headers: auth })).statusCode).toBe(400);
  });
});

describe("devices and data deletion", () => {
  it("registers a device token", async () => {
    const { app, db } = await makeApp();
    const ok = await app.inject({ method: "POST", url: "/api/devices", headers: auth, payload: { apnsToken: "ab".repeat(32), environment: "sandbox" } });
    expect(ok.statusCode).toBe(204);
    expect((db.prepare("SELECT COUNT(*) AS n FROM devices").get() as { n: number }).n).toBe(1);
    const bad = await app.inject({ method: "POST", url: "/api/devices", headers: auth, payload: { apnsToken: "xyz", environment: "sandbox" } });
    expect(bad.statusCode).toBe(400);
  });

  it("deletes everything personal on request", { timeout: 200_000 }, async () => {
    const { app, runner, db, cfg } = await makeApp();
    await app.inject({ method: "PUT", url: "/api/settings", headers: auth, payload: { profile: { name: "Brian", context: "private" } } });
    await app.inject({ method: "POST", url: "/api/devices", headers: auth, payload: { apnsToken: "cd".repeat(32), environment: "production" } });
    await app.inject({ method: "POST", url: "/api/sessions", headers: auth, payload: { durationMinutes: 5 } });
    await runner.drain();
    expect((await app.inject({ method: "DELETE", url: "/api/data", headers: auth, payload: {} })).statusCode).toBe(400);
    expect((await app.inject({ method: "DELETE", url: "/api/data", headers: auth, payload: { confirm: "DELETE" } })).statusCode).toBe(204);
    expect((await app.inject({ url: "/api/sessions", headers: auth })).json().sessions).toEqual([]);
    expect((await app.inject({ url: "/api/settings", headers: auth })).json().profile).toEqual({ name: "", lovedOnes: "", context: "" });
    expect((db.prepare("SELECT COUNT(*) AS n FROM devices").get() as { n: number }).n).toBe(0);
    expect(fs.existsSync(path.join(cfg.dataDir, "sessions"))).toBe(false);
    expect((await app.inject({ url: "/api/music", headers: auth })).json().tracks).toHaveLength(3);
  });
});

describe("audio retention", () => {
  it("archives old non-favourite audio but keeps favourites and the record", { timeout: 200_000 }, async () => {
    const { app, runner, db, cfg } = await makeApp();
    const a = (await app.inject({ method: "POST", url: "/api/sessions", headers: auth, payload: { durationMinutes: 5, theme: "presence" } })).json();
    const b = (await app.inject({ method: "POST", url: "/api/sessions", headers: auth, payload: { durationMinutes: 5, theme: "presence" } })).json();
    await runner.drain();
    await app.inject({ method: "PATCH", url: `/api/sessions/${b.id}`, headers: auth, payload: { favorite: true } });
    db.prepare("UPDATE sessions SET created_at = ?").run(new Date(Date.now() - 90 * 86_400_000).toISOString());
    const { archiveOldAudio } = await import("../src/sessions.js");
    expect(archiveOldAudio(db, cfg.dataDir, 60)).toBe(1);
    const sa = (await app.inject({ url: `/api/sessions/${a.id}`, headers: auth })).json();
    expect(sa).toMatchObject({ status: "ready", archived: true, audio: null });
    expect(sa.transcript.length).toBeGreaterThan(0);
    expect((await app.inject({ url: `/api/sessions/${a.id}/audio/voice.m4a`, headers: auth })).statusCode).toBe(404);
    const sb = (await app.inject({ url: `/api/sessions/${b.id}`, headers: auth })).json();
    expect(sb.archived).toBe(false);
    expect(sb.audio).not.toBeNull();
  });
});
