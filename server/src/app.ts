import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import Fastify, { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import multipart from "@fastify/multipart";
import { DateTime } from "luxon";
import { z } from "zod";
import type { Config } from "./config.js";
import { DB, THEMES, type Theme } from "./db.js";
import type { Providers } from "./providers/index.js";
import type { Notifier } from "./push/apns.js";
import type { JobRunner } from "./jobs.js";
import type { Scheduler } from "./scheduler.js";
import { nextDailyReadyAt, dailyWindow } from "./scheduler.js";
import { durationSchema, getSettings, settingsPatchSchema, updateSettings } from "./settings.js";
import {
  createSessionWithJob,
  dailySessionFor,
  deleteSession,
  getSessionRow,
  listSessionRows,
  sessionDir,
  toApi,
} from "./sessions.js";
import { monthSpendUsd, onDemandCountToday } from "./spend.js";
import { addUploadedTrack, deleteTrack, getTrack, listTracks, syncBuiltinTracks } from "./music.js";
import { MusicTrackRow } from "./db.js";
import { getVoicePreview } from "./previews.js";

export const VERSION = "1.0.0";

export interface AppDeps {
  cfg: Config;
  db: DB;
  providers: Providers;
  runner: JobRunner;
  scheduler: Scheduler;
  notifier: Notifier;
  logger?: boolean;
}

class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

function safeEqual(a: string, b: string): boolean {
  const ha = crypto.createHash("sha256").update(a).digest();
  const hb = crypto.createHash("sha256").update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}

/** Streams a file with HTTP Range support (AVFoundation and browsers rely on it). */
async function sendFile(req: FastifyRequest, reply: FastifyReply, file: string, type: string) {
  if (!fs.existsSync(file)) throw new HttpError(404, "not_found", "Audio not found");
  const size = fs.statSync(file).size;
  reply.header("accept-ranges", "bytes").header("content-type", type).header("cache-control", "private, max-age=31536000, immutable");
  const range = req.headers.range;
  const m = range?.match(/^bytes=(\d*)-(\d*)$/);
  if (m && (m[1] || m[2])) {
    let start = m[1] ? Number(m[1]) : size - Number(m[2]);
    let end = m[1] && m[2] ? Number(m[2]) : size - 1;
    start = Math.max(0, start);
    end = Math.min(size - 1, end);
    if (start > end) {
      reply.code(416).header("content-range", `bytes */${size}`);
      return reply.send();
    }
    reply.code(206).header("content-range", `bytes ${start}-${end}/${size}`).header("content-length", end - start + 1);
    return reply.send(fs.createReadStream(file, { start, end }));
  }
  reply.header("content-length", size);
  return reply.send(fs.createReadStream(file));
}

function trackToApi(t: MusicTrackRow) {
  return {
    id: t.id,
    title: t.title,
    source: t.source,
    license: t.license,
    durationSeconds: Math.round(t.duration_seconds),
    enabled: !!t.enabled,
    previewUrl: `/api/music/${t.id}/audio.m4a`,
  };
}

export async function buildApp(deps: AppDeps): Promise<FastifyInstance> {
  const { cfg, db, providers, runner, scheduler, notifier } = deps;
  const app = Fastify({
    logger: deps.logger ?? false,
    bodyLimit: 1024 * 1024,
    trustProxy: true,
  });
  await app.register(multipart, { limits: { fileSize: 40 * 1024 * 1024, files: 1, fields: 4 } });
  syncBuiltinTracks(db);

  const defaultVoice = () => providers.voice.defaultVoiceId();
  const settingsNow = () => getSettings(db, defaultVoice());

  app.setErrorHandler((err: unknown, _req, reply) => {
    if (err instanceof HttpError) {
      return reply.code(err.status).send({ error: { code: err.code, message: err.message } });
    }
    if (err instanceof z.ZodError) {
      return reply.code(400).send({ error: { code: "invalid", message: err.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ") } });
    }
    const e = err as { statusCode?: number; message?: string; code?: string };
    if (e.statusCode && e.statusCode < 500) {
      return reply.code(e.statusCode).send({ error: { code: e.code ?? "invalid", message: e.message ?? "Bad request" } });
    }
    app.log.error(err);
    return reply.code(500).send({ error: { code: "internal", message: "Something went wrong on the server" } });
  });

  app.get("/health", async () => ({ ok: true }));

  // Every /api route requires the bearer token.
  app.addHook("onRequest", async (req) => {
    if (!req.url.startsWith("/api/")) return;
    const header = req.headers.authorization ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
    if (!token || !safeEqual(token, cfg.appToken)) {
      await new Promise((r) => setTimeout(r, 300)); // slow down guessing
      throw new HttpError(401, "unauthorized", "Missing or invalid access token");
    }
  });

  app.get("/api/status", async () => {
    const s = settingsNow();
    return {
      version: VERSION,
      providers: {
        script: { mode: providers.script.mode, name: providers.script.name, detail: providers.note ?? providers.script.detail },
        voice: { mode: providers.voice.mode, name: providers.voice.name, detail: providers.voice.detail },
        music: {
          mode: "live",
          name: "library",
          detail: "Original ambient tracks made for Present, plus any tracks you upload (e.g. from Suno)",
        },
        push: { configured: notifier.configured, detail: notifier.detail },
      },
      spend: {
        monthUsd: monthSpendUsd(db, s.timeZone),
        monthLimitUsd: cfg.monthlySpendLimitUsd,
        dailyOnDemandCount: onDemandCountToday(db, s.timeZone),
        dailyOnDemandLimit: cfg.dailyOnDemandLimit,
      },
      scheduler: { nextRunAt: scheduler.nextRunAt(), lastError: scheduler.lastError ?? runner.lastError },
    };
  });

  app.get("/api/today", async () => {
    const s = settingsNow();
    const now = DateTime.utc();
    const w = dailyWindow(now, s, cfg);
    const row = dailySessionFor(db, w.localDate);
    const next = nextDailyReadyAt(now, s, cfg);
    return { session: row ? toApi(row) : null, nextDailyAt: next ? next.toUTC().toISO() : null };
  });

  app.get("/api/sessions", async (req) => {
    const q = z
      .object({
        favorites: z.enum(["true", "false"]).optional(),
        limit: z.coerce.number().int().min(1).max(200).optional(),
        before: z.string().max(40).optional(),
      })
      .parse(req.query);
    const rows = listSessionRows(db, { favorites: q.favorites === "true", limit: q.limit, before: q.before });
    return { sessions: rows.map(toApi) };
  });

  const sessionParam = z.object({ id: z.string().regex(/^ses_[A-Za-z0-9_-]{6,40}$/) });
  const loadSession = (params: unknown) => {
    const { id } = sessionParam.parse(params);
    const row = getSessionRow(db, id);
    if (!row) throw new HttpError(404, "not_found", "Session not found");
    return row;
  };

  app.get("/api/sessions/:id", async (req) => toApi(loadSession(req.params)));

  app.post("/api/sessions", async (req, reply) => {
    const body = z
      .object({
        theme: z.enum(THEMES as [Theme, ...Theme[]]).optional(),
        durationMinutes: durationSchema.optional(),
      })
      .strict()
      .parse(req.body ?? {});
    const s = settingsNow();
    if (onDemandCountToday(db, s.timeZone) >= cfg.dailyOnDemandLimit) {
      throw new HttpError(
        402,
        "spend_limit",
        `You've made ${cfg.dailyOnDemandLimit} extra sessions today, which is the daily limit set on the server (DAILY_ON_DEMAND_LIMIT).`,
      );
    }
    const localDate = DateTime.utc().setZone(s.timeZone).toISODate()!;
    const row = createSessionWithJob(db, {
      kind: "on_demand",
      localDate,
      theme: body.theme ?? s.themes[Math.floor(Math.random() * s.themes.length)],
      durationMinutes: body.durationMinutes ?? s.defaultDurationMinutes,
    });
    runner.kick();
    return reply.code(202).send(toApi(row!));
  });

  app.patch("/api/sessions/:id", async (req) => {
    const row = loadSession(req.params);
    const body = z.object({ favorite: z.boolean() }).strict().parse(req.body);
    db.prepare("UPDATE sessions SET favorite = ? WHERE id = ?").run(body.favorite ? 1 : 0, row.id);
    return toApi(getSessionRow(db, row.id)!);
  });

  app.delete("/api/sessions/:id", async (req, reply) => {
    const row = loadSession(req.params);
    if (row.status === "generating") throw new HttpError(409, "busy", "This session is being prepared; try again in a minute");
    deleteSession(db, cfg.dataDir, row.id);
    return reply.code(204).send();
  });

  app.get("/api/sessions/:id/audio/:stem", async (req, reply) => {
    const row = loadSession(req.params);
    const { stem } = z.object({ stem: z.enum(["voice.m4a", "music.m4a"]) }).parse({ stem: (req.params as { stem: string }).stem });
    if (row.status !== "ready") throw new HttpError(404, "not_found", "Audio isn't ready yet");
    return sendFile(req, reply, path.join(sessionDir(cfg.dataDir, row.id), stem), "audio/mp4");
  });

  app.get("/api/settings", async () => settingsNow());

  app.put("/api/settings", async (req) => {
    const patch = settingsPatchSchema.parse(req.body ?? {});
    if (patch.voiceId) {
      const voices = await providers.voice.listVoices();
      if (!voices.some((v) => v.id === patch.voiceId)) throw new HttpError(400, "invalid", "Unknown voice");
    }
    if (patch.musicTrackId && patch.musicTrackId !== "auto" && !getTrack(db, patch.musicTrackId)) {
      throw new HttpError(400, "invalid", "Unknown music track");
    }
    return updateSettings(db, defaultVoice(), patch);
  });

  app.get("/api/voices", async () => {
    const voices = await providers.voice.listVoices();
    return {
      voices: voices.map((v) => ({
        ...v,
        provider: providers.voice.mode === "live" ? "elevenlabs" : "demo",
        previewUrl: `/api/voices/${encodeURIComponent(v.id)}/preview.m4a`,
      })),
    };
  });

  app.get("/api/voices/:id/preview.m4a", async (req, reply) => {
    const { id } = z.object({ id: z.string().regex(/^[A-Za-z0-9_-]{1,64}$/) }).parse(req.params);
    const voices = await providers.voice.listVoices();
    if (!voices.some((v) => v.id === id)) throw new HttpError(404, "not_found", "Unknown voice");
    const file = await getVoicePreview(cfg, db, providers.voice, id, settingsNow().timeZone);
    return sendFile(req, reply, file, "audio/mp4");
  });

  app.get("/api/music", async () => ({ tracks: listTracks(db).map(trackToApi) }));

  app.post("/api/music", async (req, reply) => {
    const part = await req.file();
    if (!part) throw new HttpError(400, "invalid", "Attach an audio file as 'file'");
    const tmp = path.join(os.tmpdir(), `present-upload-${crypto.randomBytes(6).toString("hex")}`);
    try {
      await pipeline(part.file, fs.createWriteStream(tmp));
      if (part.file.truncated) throw new HttpError(413, "invalid", "Tracks must be 40 MB or smaller");
      const titleField = part.fields.title as { value?: string } | undefined;
      const title = (titleField?.value ?? part.filename.replace(/\.[^.]+$/, "")).trim();
      const track = await addUploadedTrack(db, cfg.dataDir, tmp, title).catch((err: Error) => {
        throw new HttpError(400, "invalid", err.message);
      });
      return reply.code(201).send(trackToApi(track));
    } finally {
      fs.rmSync(tmp, { force: true });
    }
  });

  const trackParam = z.object({ id: z.string().regex(/^[A-Za-z0-9_-]{1,64}$/) });
  app.patch("/api/music/:id", async (req) => {
    const { id } = trackParam.parse(req.params);
    const body = z.object({ enabled: z.boolean().optional(), title: z.string().min(1).max(80).optional() }).strict().parse(req.body);
    const track = getTrack(db, id);
    if (!track) throw new HttpError(404, "not_found", "Track not found");
    if (body.enabled !== undefined) db.prepare("UPDATE music_tracks SET enabled = ? WHERE id = ?").run(body.enabled ? 1 : 0, id);
    if (body.title !== undefined) db.prepare("UPDATE music_tracks SET title = ? WHERE id = ?").run(body.title, id);
    return trackToApi(getTrack(db, id)!);
  });

  app.delete("/api/music/:id", async (req, reply) => {
    const { id } = trackParam.parse(req.params);
    if (!getTrack(db, id)) throw new HttpError(404, "not_found", "Track not found");
    try {
      deleteTrack(db, id);
    } catch (err) {
      throw new HttpError(400, "invalid", (err as Error).message);
    }
    const s = settingsNow();
    if (s.musicTrackId === id) updateSettings(db, defaultVoice(), { musicTrackId: "auto" });
    return reply.code(204).send();
  });

  app.get("/api/music/:id/audio.m4a", async (req, reply) => {
    const { id } = trackParam.parse(req.params);
    const track = getTrack(db, id);
    if (!track) throw new HttpError(404, "not_found", "Track not found");
    return sendFile(req, reply, track.file, "audio/mp4");
  });

  app.post("/api/devices", async (req, reply) => {
    const body = z
      .object({ apnsToken: z.string().regex(/^[0-9a-fA-F]{32,200}$/), environment: z.enum(["sandbox", "production"]) })
      .strict()
      .parse(req.body);
    db.prepare(
      `INSERT INTO devices (token, environment, created_at) VALUES (?, ?, ?)
       ON CONFLICT(token) DO UPDATE SET environment = excluded.environment`,
    ).run(body.apnsToken.toLowerCase(), body.environment, new Date().toISOString());
    return reply.code(204).send();
  });

  app.delete("/api/data", async (req, reply) => {
    z.object({ confirm: z.literal("DELETE") }).strict().parse(req.body ?? {});
    if (runner.isBusy) throw new HttpError(409, "busy", "A session is being prepared; try again in a minute");
    db.exec(`DELETE FROM jobs; DELETE FROM sessions; DELETE FROM devices; DELETE FROM tts_cache;
             DELETE FROM music_tracks WHERE source != 'builtin'; DELETE FROM kv;`);
    for (const sub of ["sessions", "cache", "music", "previews"]) {
      fs.rmSync(path.join(cfg.dataDir, sub), { recursive: true, force: true });
    }
    db.prepare("UPDATE music_tracks SET enabled = 1, last_used_at = NULL").run();
    return reply.code(204).send();
  });

  return app;
}
