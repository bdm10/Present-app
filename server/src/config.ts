import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

function str(name: string, fallback = ""): string {
  const v = process.env[name];
  return v === undefined || v.trim() === "" ? fallback : v.trim();
}

function num(name: string, fallback: number): number {
  const v = process.env[name];
  if (v === undefined || v.trim() === "") return fallback;
  const n = Number(v);
  if (!Number.isFinite(n)) throw new Error(`${name} must be a number (got "${v}")`);
  return n;
}

function bool(name: string, fallback: boolean): boolean {
  const v = process.env[name];
  if (v === undefined || v.trim() === "") return fallback;
  return ["1", "true", "yes", "on"].includes(v.trim().toLowerCase());
}

export interface Config {
  port: number;
  host: string;
  dataDir: string;
  appToken: string;
  appTokenGenerated: boolean;
  forceDemo: boolean;

  anthropicApiKey: string;
  anthropicBaseUrl: string;
  anthropicModel: string;
  anthropicEffort: "low" | "medium" | "high";
  anthropicUsdPerMTokIn: number;
  anthropicUsdPerMTokOut: number;

  elevenLabsApiKey: string;
  elevenLabsBaseUrl: string;
  elevenLabsModel: string;
  elevenLabsDefaultVoiceId: string;
  elevenLabsVoiceIds: string[];
  elevenLabsStability: number;
  elevenLabsSimilarity: number;
  elevenLabsUsdPer1kChars: number;

  monthlySpendLimitUsd: number;
  dailyOnDemandLimit: number;

  dailyLeadMinutes: number;
  catchUpHours: number;
  maxJobAttempts: number;

  apnsKeyId: string;
  apnsTeamId: string;
  apnsBundleId: string;
  apnsKeyP8: string;
}

/**
 * Reads configuration from the environment. APP_TOKEN protects every API route;
 * when it is not provided (local development only) a random token is generated
 * once and stored in DATA_DIR so restarts keep working.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const prev = process.env;
  process.env = env;
  try {
    const dataDir = path.resolve(str("DATA_DIR", "./data"));
    fs.mkdirSync(dataDir, { recursive: true });

    let appToken = str("APP_TOKEN");
    let appTokenGenerated = false;
    if (!appToken) {
      const tokenFile = path.join(dataDir, "app-token.txt");
      if (fs.existsSync(tokenFile)) {
        appToken = fs.readFileSync(tokenFile, "utf8").trim();
      } else {
        appToken = crypto.randomBytes(24).toString("base64url");
        fs.writeFileSync(tokenFile, appToken + "\n", { mode: 0o600 });
      }
      appTokenGenerated = true;
    }
    if (appToken.length < 16) throw new Error("APP_TOKEN must be at least 16 characters");

    let apnsKeyP8 = str("APNS_KEY_P8").replace(/\\n/g, "\n");
    const apnsKeyPath = str("APNS_KEY_PATH");
    if (!apnsKeyP8 && apnsKeyPath && fs.existsSync(apnsKeyPath)) {
      apnsKeyP8 = fs.readFileSync(apnsKeyPath, "utf8");
    }

    const effort = str("ANTHROPIC_EFFORT", "medium");
    if (!["low", "medium", "high"].includes(effort)) throw new Error("ANTHROPIC_EFFORT must be low, medium or high");

    return {
      port: num("PORT", 8787),
      host: str("HOST", "0.0.0.0"),
      dataDir,
      appToken,
      appTokenGenerated,
      forceDemo: bool("FORCE_DEMO", false),

      anthropicApiKey: str("ANTHROPIC_API_KEY"),
      anthropicBaseUrl: str("PRESENT_ANTHROPIC_BASE_URL", "https://api.anthropic.com"),
      anthropicModel: str("ANTHROPIC_MODEL", "claude-opus-5-5"),
      anthropicEffort: effort as Config["anthropicEffort"],
      anthropicUsdPerMTokIn: num("ANTHROPIC_USD_PER_MTOK_IN", 4),
      anthropicUsdPerMTokOut: num("ANTHROPIC_USD_PER_MTOK_OUT", 20),

      elevenLabsApiKey: str("ELEVENLABS_API_KEY"),
      elevenLabsBaseUrl: str("PRESENT_ELEVENLABS_BASE_URL", "https://api.elevenlabs.io"),
      elevenLabsModel: str("ELEVENLABS_MODEL", "eleven_v4"),
      elevenLabsDefaultVoiceId: str("ELEVENLABS_DEFAULT_VOICE_ID"),
      elevenLabsVoiceIds: str("ELEVENLABS_VOICE_IDS")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean),
      elevenLabsStability: num("ELEVENLABS_STABILITY", 0.65),
      elevenLabsSimilarity: num("ELEVENLABS_SIMILARITY", 0.8),
      elevenLabsUsdPer1kChars: num("ELEVENLABS_USD_PER_1K_CHARS", 0.08),

      monthlySpendLimitUsd: num("MONTHLY_SPEND_LIMIT_USD", 15),
      dailyOnDemandLimit: num("DAILY_ON_DEMAND_LIMIT", 4),

      dailyLeadMinutes: num("DAILY_LEAD_MINUTES", 30),
      catchUpHours: num("CATCH_UP_HOURS", 12),
      maxJobAttempts: num("MAX_JOB_ATTEMPTS", 4),

      apnsKeyId: str("APNS_KEY_ID"),
      apnsTeamId: str("APNS_TEAM_ID"),
      apnsBundleId: str("APNS_BUNDLE_ID", "com.present.meditation"),
      apnsKeyP8,
    };
  } finally {
    process.env = prev;
  }
}
