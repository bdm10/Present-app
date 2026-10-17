// Manual smoke test: generates one demo session per duration and prints the result.
import { loadConfig } from "../src/config.js";
import { openDb } from "../src/db.js";
import { createProviders } from "../src/providers/index.js";
import { generateSession } from "../src/pipeline.js";
import { createSessionWithJob, getSessionRow } from "../src/sessions.js";
import { syncBuiltinTracks } from "../src/music.js";
import { probeDuration } from "../src/audio/ffmpeg.js";
import type { Theme, Duration } from "../src/db.js";

const cfg = loadConfig();
const db = openDb(cfg.dataDir);
syncBuiltinTracks(db);
const providers = createProviders(cfg, db);
const log = { info: (o: object) => console.log(JSON.stringify(o)), warn: (o: object) => console.warn(JSON.stringify(o)) };
const cases = (process.argv[2] ?? "presence:5").split(",");
for (const c of cases) {
  const [theme, d] = c.split(":");
  const row = createSessionWithJob(db, { kind: "on_demand", localDate: "2026-10-17", theme: theme as Theme, durationMinutes: Number(d) as Duration })!;
  const t0 = Date.now();
  await generateSession({ cfg, db, providers, log }, row.id);
  const done = getSessionRow(db, row.id)!;
  const dir = `${cfg.dataDir}/sessions/${row.id}`;
  console.log(c, done.status, done.title, `${((Date.now() - t0) / 1000).toFixed(1)}s`,
    "voice", (await probeDuration(`${dir}/voice.m4a`)).toFixed(3), "music", (await probeDuration(`${dir}/music.m4a`)).toFixed(3), dir);
}
