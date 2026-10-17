import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadConfig, type Config } from "../src/config.js";
import { openDb, type DB } from "../src/db.js";
import { createProviders, type Providers } from "../src/providers/index.js";
import { syncBuiltinTracks } from "../src/music.js";
import type { PipelineContext } from "../src/pipeline.js";

export const TOKEN = "test-token-0123456789abcdef";

export function tempDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "present-test-"));
}

export function testEnv(extra: Record<string, string> = {}): { cfg: Config; db: DB; providers: Providers; ctx: PipelineContext } {
  const cfg = loadConfig({ DATA_DIR: tempDir(), APP_TOKEN: TOKEN, FORCE_DEMO: "true", ...extra });
  const db = openDb(cfg.dataDir);
  syncBuiltinTracks(db);
  const providers = createProviders(cfg, db);
  const ctx: PipelineContext = { cfg, db, providers, log: { info: () => {}, warn: () => {} } };
  return { cfg, db, providers, ctx };
}
