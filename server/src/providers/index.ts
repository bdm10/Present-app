import type { Config } from "../config.js";
import type { DB } from "../db.js";
import { AnthropicScriptProvider } from "./script/anthropic.js";
import { DemoScriptProvider } from "./script/demo.js";
import { DemoVoiceProvider } from "./voice/demo.js";
import { ElevenLabsVoiceProvider } from "./voice/elevenlabs.js";
import type { ScriptProvider, VoiceProvider } from "./types.js";

export interface Providers {
  script: ScriptProvider;
  voice: VoiceProvider;
  /** Explains any mismatch, e.g. Claude configured but no ElevenLabs key. */
  note: string | null;
}

/**
 * Picks real providers when their keys are present, demo ones otherwise.
 * New scripts need a real voice to read them, so a live script provider is only
 * used together with a live voice.
 */
export function createProviders(cfg: Config, db: DB): Providers {
  const voiceLive = !cfg.forceDemo && !!cfg.elevenLabsApiKey;
  const scriptKey = !cfg.forceDemo && !!cfg.anthropicApiKey;
  const voice: VoiceProvider = voiceLive ? new ElevenLabsVoiceProvider(cfg, db) : new DemoVoiceProvider();
  let note: string | null = null;
  let script: ScriptProvider;
  if (scriptKey && voiceLive) {
    script = new AnthropicScriptProvider(cfg);
  } else {
    script = new DemoScriptProvider();
    if (scriptKey && !voiceLive) {
      note = "ANTHROPIC_API_KEY is set but ELEVENLABS_API_KEY is not, so demo scripts are used (the demo voice can only read those).";
    }
  }
  return { script, voice, note };
}
