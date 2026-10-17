import fs from "node:fs";
import path from "node:path";
import type { Config } from "./config.js";
import type { DB } from "./db.js";
import { encodeClip } from "./audio/ffmpeg.js";
import { ASSETS_DIR } from "./paths.js";
import type { VoiceProvider } from "./providers/types.js";
import { assertWithinBudget, recordSpend } from "./spend.js";

export const PREVIEW_TEXT =
  "Take a moment to arrive. Let your shoulders soften, and let the next breath be a little slower than the last. There's nowhere else you need to be.";

/** Returns a short sample of a voice reading meditation text, generating and caching it once. */
export async function getVoicePreview(cfg: Config, db: DB, voice: VoiceProvider, voiceId: string, timeZone: string): Promise<string> {
  if (voice.mode === "demo") return path.join(ASSETS_DIR, "demo", "voice", voiceId, "preview.m4a");
  const dir = path.join(cfg.dataDir, "previews");
  fs.mkdirSync(dir, { recursive: true });
  const out = path.join(dir, `${voice.model}-${voiceId}.m4a`);
  if (fs.existsSync(out)) return out;
  const estimate = (PREVIEW_TEXT.length / 1000) * cfg.elevenLabsUsdPer1kChars;
  assertWithinBudget(cfg, db, timeZone, estimate);
  const result = await voice.synthesize({ voiceId, text: PREVIEW_TEXT });
  recordSpend(db, voice.name, result.chars, result.costUsd, null, `voice preview ${voiceId}`);
  await encodeClip(result.file, out);
  return out;
}
