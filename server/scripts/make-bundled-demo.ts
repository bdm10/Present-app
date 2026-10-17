// Renders the 5-minute demo session that ships inside the iPhone app (plays with no server).
//   npx tsx scripts/make-bundled-demo.ts ../ios/Present/Resources/DemoSession
import fs from "node:fs";
import path from "node:path";
import { loadConfig } from "../src/config.js";
import { openDb } from "../src/db.js";
import { createProviders } from "../src/providers/index.js";
import { generateSession } from "../src/pipeline.js";
import { createSessionWithJob, getSessionRow, sessionDir, toApi } from "../src/sessions.js";
import { syncBuiltinTracks } from "../src/music.js";
import { updateSettings } from "../src/settings.js";

const out = path.resolve(process.argv[2] ?? "../ios/Present/Resources/DemoSession");
const dataDir = fs.mkdtempSync("/tmp/present-bundle-");
const cfg = loadConfig({ DATA_DIR: dataDir, APP_TOKEN: "bundle-build-token-0000", FORCE_DEMO: "true" });
const db = openDb(cfg.dataDir);
syncBuiltinTracks(db);
const providers = createProviders(cfg, db);
updateSettings(db, "demo-wren", { voiceId: "demo-wren", musicTrackId: "builtin-linen" });
const row = createSessionWithJob(db, { kind: "on_demand", localDate: "2026-10-17", theme: "presence", durationMinutes: 5 })!;
await generateSession({ cfg, db, providers, log: { info: () => {}, warn: () => {} } }, row.id);
const done = getSessionRow(db, row.id)!;
if (done.status !== "ready") throw new Error("Bundled demo failed to render");
const api = { ...toApi(done), id: "demo_arriving", createdAt: "2026-10-17T07:00:00.000Z", audio: null };
fs.mkdirSync(out, { recursive: true });
fs.copyFileSync(path.join(sessionDir(dataDir, row.id), "voice.m4a"), path.join(out, "voice.m4a"));
fs.copyFileSync(path.join(sessionDir(dataDir, row.id), "music.m4a"), path.join(out, "music.m4a"));
fs.writeFileSync(path.join(out, "session.json"), JSON.stringify(api, null, 2) + "\n");
fs.rmSync(dataDir, { recursive: true, force: true });
console.log(`Wrote ${api.title} (${api.durationSeconds}s) to ${out}`);
