import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { Config } from "../../config.js";
import { DB, nowIso } from "../../db.js";
import type { TtsRequest, TtsResult, VoiceInfo, VoiceProvider } from "../types.js";

const TAG_MODELS = new Set(["eleven_v3", "eleven_v4", "eleven_v4_turbo"]);
// v3 does not support request stitching; v4 and the v2/v2.5 models do.
const NO_STITCH_MODELS = new Set(["eleven_v3"]);
// v3 and v4 ignore previous_text/next_text style context in favour of request ids.
const TEXT_CONTEXT_MODELS = new Set(["eleven_multilingual_v2", "eleven_turbo_v2_5", "eleven_flash_v2_5", "eleven_flash_v2"]);

interface ApiVoice {
  voice_id: string;
  name: string;
  description?: string | null;
  labels?: Record<string, string>;
  category?: string;
}

export class ElevenLabsError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export class ElevenLabsVoiceProvider implements VoiceProvider {
  readonly name = "elevenlabs";
  readonly mode = "live" as const;
  private voicesCache: { at: number; voices: VoiceInfo[] } | null = null;
  private cacheDir: string;

  constructor(private cfg: Config, private db: DB) {
    this.cacheDir = path.join(cfg.dataDir, "cache", "tts");
    fs.mkdirSync(this.cacheDir, { recursive: true });
  }

  get model(): string {
    return this.cfg.elevenLabsModel;
  }
  get detail(): string {
    return `ElevenLabs ${this.cfg.elevenLabsModel} narrates each session`;
  }
  get supportsAudioTags(): boolean {
    return TAG_MODELS.has(this.cfg.elevenLabsModel);
  }
  get supportsRequestStitching(): boolean {
    return !NO_STITCH_MODELS.has(this.cfg.elevenLabsModel);
  }

  defaultVoiceId(): string {
    return this.cfg.elevenLabsDefaultVoiceId || this.cfg.elevenLabsVoiceIds[0] || "";
  }

  private async request(pathname: string, init: RequestInit & { timeoutMs?: number } = {}): Promise<Response> {
    let lastErr: unknown;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const res = await fetch(this.cfg.elevenLabsBaseUrl + pathname, {
          ...init,
          headers: { "xi-api-key": this.cfg.elevenLabsApiKey, ...(init.headers ?? {}) },
          signal: AbortSignal.timeout(init.timeoutMs ?? 90_000),
        });
        if (res.ok) return res;
        const body = (await res.text()).slice(0, 500);
        const err = new ElevenLabsError(`ElevenLabs ${res.status}: ${body}`, res.status);
        if (res.status !== 429 && res.status < 500) throw err;
        lastErr = err;
      } catch (err) {
        if (err instanceof ElevenLabsError && err.status !== 429 && err.status < 500) throw err;
        lastErr = err;
      }
      await new Promise((r) => setTimeout(r, 1500 * 2 ** attempt));
    }
    throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
  }

  async listVoices(): Promise<VoiceInfo[]> {
    if (this.voicesCache && Date.now() - this.voicesCache.at < 60 * 60 * 1000) return this.voicesCache.voices;
    const res = await this.request("/v2/voices?page_size=100&include_total_count=false");
    const data = (await res.json()) as { voices: ApiVoice[] };
    let voices = data.voices;
    const curated = this.cfg.elevenLabsVoiceIds;
    if (curated.length) {
      voices = curated.map((id) => voices.find((v) => v.voice_id === id)).filter((v): v is ApiVoice => !!v);
    } else {
      // Put voices described as calm, soothing or narrative first.
      const score = (v: ApiVoice) => {
        const text = `${v.description ?? ""} ${Object.values(v.labels ?? {}).join(" ")}`.toLowerCase();
        return /(calm|sooth|meditat|relax|gentle|warm|narrat|soft)/.test(text) ? 0 : 1;
      };
      voices = [...voices].sort((a, b) => score(a) - score(b)).slice(0, 30);
    }
    const out = voices.map((v) => ({
      id: v.voice_id,
      name: v.name,
      description: describe(v),
    }));
    this.voicesCache = { at: Date.now(), voices: out };
    return out;
  }

  private voiceSettings(): Record<string, unknown> {
    const model = this.cfg.elevenLabsModel;
    if (model.startsWith("eleven_v4")) {
      // v4 honours stability and similarity only.
      return { stability: this.cfg.elevenLabsStability, similarity_boost: this.cfg.elevenLabsSimilarity };
    }
    if (model === "eleven_v3") {
      return { stability: 0.5, similarity_boost: this.cfg.elevenLabsSimilarity };
    }
    return {
      stability: this.cfg.elevenLabsStability,
      similarity_boost: this.cfg.elevenLabsSimilarity,
      style: 0,
      use_speaker_boost: true,
      speed: 0.9,
    };
  }

  async synthesize(req: TtsRequest): Promise<TtsResult> {
    const model = this.cfg.elevenLabsModel;
    const settings = this.voiceSettings();
    const useTextContext = TEXT_CONTEXT_MODELS.has(model);
    // Cache on content only (not request ids) so a retried job reuses audio it already paid for.
    const key = crypto
      .createHash("sha256")
      .update(JSON.stringify([model, req.voiceId, settings, req.text, useTextContext ? req.previousText ?? "" : ""]))
      .digest("hex");
    const cached = this.db.prepare("SELECT file, request_id FROM tts_cache WHERE key = ?").get(key) as
      | { file: string; request_id: string | null }
      | undefined;
    if (cached && fs.existsSync(cached.file)) {
      return { file: cached.file, requestId: cached.request_id ?? undefined, chars: 0, costUsd: 0, cached: true };
    }

    const body: Record<string, unknown> = { text: req.text, model_id: model, voice_settings: settings };
    if (useTextContext) {
      if (req.previousText) body.previous_text = req.previousText;
      if (req.nextText) body.next_text = req.nextText;
    }
    if (this.supportsRequestStitching && req.previousRequestIds?.length) {
      body.previous_request_ids = req.previousRequestIds.slice(-3);
    }
    const res = await this.request(
      `/v1/text-to-speech/${encodeURIComponent(req.voiceId)}?output_format=mp3_44100_128`,
      { method: "POST", headers: { "content-type": "application/json", accept: "audio/mpeg" }, body: JSON.stringify(body) },
    );
    const audio = Buffer.from(await res.arrayBuffer());
    if (audio.length < 500) throw new Error("ElevenLabs returned an empty clip");
    const file = path.join(this.cacheDir, `${key}.mp3`);
    fs.writeFileSync(file, audio);
    const requestId = res.headers.get("request-id") ?? undefined;
    this.db
      .prepare("INSERT OR REPLACE INTO tts_cache (key, file, request_id, created_at) VALUES (?, ?, ?, ?)")
      .run(key, file, requestId ?? null, nowIso());
    const chars = req.text.length;
    return { file, requestId, chars, costUsd: (chars / 1000) * this.cfg.elevenLabsUsdPer1kChars, cached: false };
  }
}

function describe(v: ApiVoice): string {
  const l = v.labels ?? {};
  const parts = [l.description, l.descriptive, l.age, l.accent, l.gender, l.use_case].filter(
    (p): p is string => typeof p === "string" && p.length > 0,
  );
  const text = parts.length ? parts.join(", ") : v.description ?? "";
  return text.replace(/_/g, " ").slice(0, 120);
}
