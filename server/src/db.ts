import { DatabaseSync } from "node:sqlite";
import path from "node:path";

export type Theme =
  | "presence"
  | "gratitude"
  | "stress"
  | "sleep"
  | "family"
  | "letting-go-of-work"
  | "slowing-down";

export const THEMES: Theme[] = [
  "presence",
  "gratitude",
  "stress",
  "sleep",
  "family",
  "letting-go-of-work",
  "slowing-down",
];

export const DURATIONS = [5, 10, 15, 20] as const;
export type Duration = (typeof DURATIONS)[number];

export type SessionStatus = "queued" | "generating" | "ready" | "failed";

export interface SessionRow {
  id: string;
  kind: "daily" | "on_demand";
  local_date: string;
  created_at: string;
  status: SessionStatus;
  status_detail: string | null;
  theme: Theme;
  duration_minutes: Duration;
  title: string | null;
  summary: string | null;
  reflection_question: string | null;
  duration_seconds: number | null;
  favorite: number;
  demo: number;
  providers: string | null;
  voice_name: string | null;
  music_title: string | null;
  music_track_id: string | null;
  voice_bytes: number | null;
  music_bytes: number | null;
  transcript: string | null;
  script: string | null;
  error: string | null;
  ready_at: string | null;
  notified_at: string | null;
  cost_usd: number;
}

export interface JobRow {
  id: string;
  session_id: string;
  status: "queued" | "running" | "done" | "failed";
  attempts: number;
  next_attempt_at: string;
  lease_until: string | null;
  last_error: string | null;
  created_at: string;
  updated_at: string;
}

export interface MusicTrackRow {
  id: string;
  title: string;
  source: "builtin" | "upload" | "generated";
  license: string;
  file: string;
  duration_seconds: number;
  loudness_lufs: number | null;
  mood: string | null;
  enabled: number;
  last_used_at: string | null;
  created_at: string;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('daily','on_demand')),
  local_date TEXT NOT NULL,
  created_at TEXT NOT NULL,
  status TEXT NOT NULL,
  status_detail TEXT,
  theme TEXT NOT NULL,
  duration_minutes INTEGER NOT NULL,
  title TEXT,
  summary TEXT,
  reflection_question TEXT,
  duration_seconds REAL,
  favorite INTEGER NOT NULL DEFAULT 0,
  demo INTEGER NOT NULL DEFAULT 0,
  providers TEXT,
  voice_name TEXT,
  music_title TEXT,
  music_track_id TEXT,
  voice_bytes INTEGER,
  music_bytes INTEGER,
  transcript TEXT,
  script TEXT,
  error TEXT,
  ready_at TEXT,
  notified_at TEXT,
  cost_usd REAL NOT NULL DEFAULT 0
);
-- Exactly one daily session per local date: the core duplicate-prevention guarantee.
CREATE UNIQUE INDEX IF NOT EXISTS sessions_one_daily_per_day ON sessions(local_date) WHERE kind = 'daily';
CREATE INDEX IF NOT EXISTS sessions_created ON sessions(created_at);

CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL UNIQUE REFERENCES sessions(id) ON DELETE CASCADE,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  lease_until TEXT,
  last_error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS jobs_due ON jobs(status, next_attempt_at);

CREATE TABLE IF NOT EXISTS spend (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  provider TEXT NOT NULL,
  units REAL NOT NULL,
  usd REAL NOT NULL,
  session_id TEXT,
  note TEXT
);
CREATE INDEX IF NOT EXISTS spend_ts ON spend(ts);

CREATE TABLE IF NOT EXISTS devices (
  token TEXT PRIMARY KEY,
  environment TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_error TEXT
);

CREATE TABLE IF NOT EXISTS tts_cache (
  key TEXT PRIMARY KEY,
  file TEXT NOT NULL,
  request_id TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS music_tracks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  source TEXT NOT NULL,
  license TEXT NOT NULL,
  file TEXT NOT NULL,
  duration_seconds REAL NOT NULL,
  loudness_lufs REAL,
  mood TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,
  last_used_at TEXT,
  created_at TEXT NOT NULL
);
`;

export type DB = DatabaseSync;

export function openDb(dataDir: string): DB {
  const file = dataDir === ":memory:" ? ":memory:" : path.join(dataDir, "present.db");
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec("PRAGMA foreign_keys = ON;");
  db.exec("PRAGMA busy_timeout = 5000;");
  db.exec(SCHEMA);
  return db;
}

export function nowIso(): string {
  return new Date().toISOString();
}

/** Runs fn inside a transaction (BEGIN IMMEDIATE so concurrent writers serialise). */
export function tx<T>(db: DB, fn: () => T): T {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = fn();
    db.exec("COMMIT");
    return result;
  } catch (err) {
    db.exec("ROLLBACK");
    throw err;
  }
}

export function kvGet<T>(db: DB, key: string): T | undefined {
  const row = db.prepare("SELECT value FROM kv WHERE key = ?").get(key) as { value: string } | undefined;
  return row ? (JSON.parse(row.value) as T) : undefined;
}

export function kvSet(db: DB, key: string, value: unknown): void {
  db.prepare("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(
    key,
    JSON.stringify(value),
  );
}

export function kvDelete(db: DB, key: string): void {
  db.prepare("DELETE FROM kv WHERE key = ?").run(key);
}
