import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { DB, SessionRow, nowIso, tx, type Duration, type Theme } from "./db.js";

export function newId(prefix: string): string {
  return `${prefix}_${crypto.randomBytes(9).toString("base64url")}`;
}

export function sessionDir(dataDir: string, id: string): string {
  if (!/^ses_[A-Za-z0-9_-]+$/.test(id)) throw new Error("Invalid session id");
  return path.join(dataDir, "sessions", id);
}

export interface ApiSession {
  id: string;
  kind: "daily" | "on_demand";
  localDate: string;
  createdAt: string;
  status: SessionRow["status"];
  statusDetail: string | null;
  theme: Theme;
  durationMinutes: Duration;
  title: string | null;
  summary: string | null;
  reflectionQuestion: string | null;
  durationSeconds: number | null;
  favorite: boolean;
  demo: boolean;
  /** Audio removed from the server by the retention policy (copies on the phone still play). */
  archived: boolean;
  providers: { script: string; voice: string; music: string } | null;
  voiceName: string | null;
  musicTitle: string | null;
  audio: { voiceUrl: string; musicUrl: string; voiceBytes: number; musicBytes: number } | null;
  transcript: { text: string; startSeconds: number }[] | null;
}

export function toApi(row: SessionRow): ApiSession {
  const ready = row.status === "ready" && !row.audio_archived;
  return {
    id: row.id,
    kind: row.kind,
    localDate: row.local_date,
    createdAt: row.created_at,
    status: row.status,
    statusDetail: row.status === "failed" ? row.error ?? row.status_detail : row.status_detail,
    theme: row.theme,
    durationMinutes: row.duration_minutes,
    title: row.title,
    summary: row.summary,
    reflectionQuestion: row.reflection_question,
    durationSeconds: row.duration_seconds,
    favorite: !!row.favorite,
    demo: !!row.demo,
    archived: !!row.audio_archived,
    providers: row.providers ? JSON.parse(row.providers) : null,
    voiceName: row.voice_name,
    musicTitle: row.music_title,
    audio: ready
      ? {
          voiceUrl: `/api/sessions/${row.id}/audio/voice.m4a`,
          musicUrl: `/api/sessions/${row.id}/audio/music.m4a`,
          voiceBytes: row.voice_bytes ?? 0,
          musicBytes: row.music_bytes ?? 0,
        }
      : null,
    transcript: row.status === "ready" && row.transcript ? JSON.parse(row.transcript) : null,
  };
}

export function getSessionRow(db: DB, id: string): SessionRow | undefined {
  return db.prepare("SELECT * FROM sessions WHERE id = ?").get(id) as unknown as SessionRow | undefined;
}

export function listSessionRows(db: DB, opts: { favorites?: boolean; limit?: number; before?: string }): SessionRow[] {
  const where: string[] = [];
  const params: (string | number)[] = [];
  if (opts.favorites) where.push("favorite = 1");
  if (opts.before) {
    where.push("created_at < ?");
    params.push(opts.before);
  }
  const limit = Math.min(Math.max(opts.limit ?? 50, 1), 200);
  const sql = `SELECT * FROM sessions ${where.length ? "WHERE " + where.join(" AND ") : ""} ORDER BY created_at DESC LIMIT ${limit}`;
  return db.prepare(sql).all(...params) as unknown as SessionRow[];
}

export function dailySessionFor(db: DB, localDate: string): SessionRow | undefined {
  return db.prepare("SELECT * FROM sessions WHERE kind = 'daily' AND local_date = ?").get(localDate) as unknown as
    | SessionRow
    | undefined;
}

/**
 * Creates a session and its generation job atomically. For daily sessions the unique
 * index on local_date makes this idempotent: a second call for the same day returns null.
 */
export function createSessionWithJob(
  db: DB,
  input: { kind: "daily" | "on_demand"; localDate: string; theme: Theme; durationMinutes: Duration },
): SessionRow | null {
  return tx(db, () => {
    const id = newId("ses");
    const now = nowIso();
    const res = db
      .prepare(
        `INSERT OR IGNORE INTO sessions (id, kind, local_date, created_at, status, status_detail, theme, duration_minutes)
         VALUES (?, ?, ?, ?, 'queued', 'Waiting to start', ?, ?)`,
      )
      .run(id, input.kind, input.localDate, now, input.theme, input.durationMinutes);
    if (res.changes === 0) return null;
    db.prepare(
      `INSERT INTO jobs (id, session_id, status, attempts, next_attempt_at, created_at, updated_at)
       VALUES (?, ?, 'queued', 0, ?, ?, ?)`,
    ).run(newId("job"), id, now, now, now);
    return getSessionRow(db, id)!;
  });
}

export function setStatus(db: DB, id: string, status: SessionRow["status"], detail: string | null): void {
  db.prepare("UPDATE sessions SET status = ?, status_detail = ? WHERE id = ?").run(status, detail, id);
}

export function deleteSession(db: DB, dataDir: string, id: string): boolean {
  const res = db.prepare("DELETE FROM sessions WHERE id = ?").run(id);
  fs.rmSync(sessionDir(dataDir, id), { recursive: true, force: true });
  return res.changes > 0;
}

/**
 * Frees disk space: removes the audio of sessions older than `days` (favourites are kept).
 * The record, transcript and reflection question stay, and the app keeps its own downloads.
 */
export function archiveOldAudio(db: DB, dataDir: string, days: number): number {
  if (days <= 0) return 0;
  const cutoff = new Date(Date.now() - days * 86_400_000).toISOString();
  const rows = db
    .prepare("SELECT id FROM sessions WHERE status = 'ready' AND favorite = 0 AND audio_archived = 0 AND created_at < ?")
    .all(cutoff) as { id: string }[];
  for (const { id } of rows) {
    const dir = sessionDir(dataDir, id);
    fs.rmSync(path.join(dir, "voice.m4a"), { force: true });
    fs.rmSync(path.join(dir, "music.m4a"), { force: true });
    db.prepare("UPDATE sessions SET audio_archived = 1 WHERE id = ?").run(id);
  }
  return rows.length;
}
