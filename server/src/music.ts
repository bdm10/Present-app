import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { DB, MusicTrackRow, nowIso, type Theme } from "./db.js";
import { ASSETS_DIR } from "./paths.js";
import { measureLoudness, probeDuration, transcodeTrack } from "./audio/ffmpeg.js";

interface BuiltinManifest {
  tracks: {
    slug: string;
    title: string;
    file: string;
    durationSeconds: number;
    loudnessLufs: number;
    mood: string;
    license: string;
  }[];
}

export const UPLOAD_LICENSE =
  "Uploaded by you. If it came from Suno, a paid plan is needed for anything beyond personal use.";

/** Registers the built-in ambient tracks shipped in server/assets/music. */
export function syncBuiltinTracks(db: DB): void {
  const manifestFile = path.join(ASSETS_DIR, "music", "manifest.json");
  if (!fs.existsSync(manifestFile)) return;
  const manifest = JSON.parse(fs.readFileSync(manifestFile, "utf8")) as BuiltinManifest;
  const keep = new Set<string>();
  for (const t of manifest.tracks) {
    const id = `builtin-${t.slug}`;
    keep.add(id);
    const file = path.join(ASSETS_DIR, "music", t.file);
    db.prepare(
      `INSERT INTO music_tracks (id, title, source, license, file, duration_seconds, loudness_lufs, mood, enabled, created_at)
       VALUES (?, ?, 'builtin', ?, ?, ?, ?, ?, 1, ?)
       ON CONFLICT(id) DO UPDATE SET title = excluded.title, license = excluded.license, file = excluded.file,
         duration_seconds = excluded.duration_seconds, loudness_lufs = excluded.loudness_lufs, mood = excluded.mood`,
    ).run(id, t.title, t.license, file, t.durationSeconds, t.loudnessLufs, t.mood, nowIso());
  }
  const existing = db.prepare("SELECT id FROM music_tracks WHERE source = 'builtin'").all() as { id: string }[];
  for (const row of existing) if (!keep.has(row.id)) db.prepare("DELETE FROM music_tracks WHERE id = ?").run(row.id);
}

export function listTracks(db: DB): MusicTrackRow[] {
  return db
    .prepare("SELECT * FROM music_tracks ORDER BY CASE source WHEN 'builtin' THEN 0 ELSE 1 END, created_at")
    .all() as unknown as MusicTrackRow[];
}

export function getTrack(db: DB, id: string): MusicTrackRow | undefined {
  return db.prepare("SELECT * FROM music_tracks WHERE id = ?").get(id) as unknown as MusicTrackRow | undefined;
}

export async function addUploadedTrack(db: DB, dataDir: string, tmpFile: string, title: string): Promise<MusicTrackRow> {
  const id = "upload-" + crypto.randomBytes(6).toString("hex");
  const dir = path.join(dataDir, "music");
  fs.mkdirSync(dir, { recursive: true });
  const out = path.join(dir, `${id}.m4a`);
  try {
    await transcodeTrack(tmpFile, out);
  } catch {
    fs.rmSync(out, { force: true });
    throw new Error("That file couldn't be read as audio. Try an MP3, M4A or WAV.");
  }
  const duration = await probeDuration(out);
  if (duration < 20) {
    fs.rmSync(out, { force: true });
    throw new Error("Tracks need to be at least 20 seconds long.");
  }
  const lufs = await measureLoudness(out);
  db.prepare(
    `INSERT INTO music_tracks (id, title, source, license, file, duration_seconds, loudness_lufs, mood, enabled, created_at)
     VALUES (?, ?, 'upload', ?, ?, ?, ?, NULL, 1, ?)`,
  ).run(id, title.slice(0, 80) || "Uploaded track", UPLOAD_LICENSE, out, duration, lufs, nowIso());
  return getTrack(db, id)!;
}

export function deleteTrack(db: DB, id: string): void {
  const t = getTrack(db, id);
  if (!t) return;
  if (t.source === "builtin") throw new Error("Built-in tracks can be turned off but not deleted.");
  db.prepare("DELETE FROM music_tracks WHERE id = ?").run(id);
  fs.rmSync(t.file, { force: true });
}

/** Picks a track: the chosen one if set and enabled, otherwise a fitting, least recently used track. */
export function pickTrack(db: DB, preferredId: string, theme: Theme): MusicTrackRow {
  const enabled = listTracks(db).filter((t) => t.enabled && fs.existsSync(t.file));
  if (preferredId !== "auto") {
    const chosen = enabled.find((t) => t.id === preferredId);
    if (chosen) return chosen;
  }
  if (enabled.length === 0) {
    const any = listTracks(db).find((t) => fs.existsSync(t.file));
    if (!any) throw new Error("No background music is available");
    return any;
  }
  const wantsSleep = theme === "sleep";
  const fitting = enabled.filter((t) => (t.mood === "sleep") === wantsSleep || t.source !== "builtin");
  const pool = fitting.length ? fitting : enabled;
  pool.sort((a, b) => (a.last_used_at ?? "").localeCompare(b.last_used_at ?? ""));
  return pool[0];
}

export function markTrackUsed(db: DB, id: string): void {
  db.prepare("UPDATE music_tracks SET last_used_at = ? WHERE id = ?").run(nowIso(), id);
}
