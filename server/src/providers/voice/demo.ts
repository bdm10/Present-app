import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { ASSETS_DIR } from "../../paths.js";
import type { TtsRequest, TtsResult, VoiceInfo, VoiceProvider } from "../types.js";

interface Manifest {
  engine: string;
  license: string;
  voices: VoiceInfo[];
}

export function demoClipName(text: string): string {
  return crypto.createHash("sha1").update(text.trim()).digest("hex").slice(0, 16) + ".m4a";
}

/**
 * Demo mode narration: clips pre-rendered offline with the open-source Piper TTS engine
 * for the demo scripts only. It is not ElevenLabs and is labelled as demo everywhere.
 */
export class DemoVoiceProvider implements VoiceProvider {
  readonly name = "demo";
  readonly mode = "demo" as const;
  readonly model = "piper-offline";
  readonly supportsAudioTags = false;
  readonly supportsRequestStitching = false;
  private dir = path.join(ASSETS_DIR, "demo", "voice");
  private manifest: Manifest;

  constructor() {
    const file = path.join(this.dir, "manifest.json");
    this.manifest = fs.existsSync(file)
      ? (JSON.parse(fs.readFileSync(file, "utf8")) as Manifest)
      : { engine: "missing", license: "", voices: [] };
  }

  get detail(): string {
    return "Demo mode: offline sample voice (Piper, open source). Add ELEVENLABS_API_KEY for ElevenLabs narration";
  }

  async listVoices(): Promise<VoiceInfo[]> {
    return this.manifest.voices;
  }

  defaultVoiceId(): string {
    return this.manifest.voices[0]?.id ?? "demo";
  }

  clipPath(voiceId: string, text: string): string {
    return path.join(this.dir, voiceId, demoClipName(text));
  }

  async synthesize(req: TtsRequest): Promise<TtsResult> {
    const voiceId = this.manifest.voices.some((v) => v.id === req.voiceId) ? req.voiceId : this.defaultVoiceId();
    const file = this.clipPath(voiceId, req.text);
    if (!fs.existsSync(file)) {
      throw new Error("Demo voice can only read the built-in demo scripts. Add ELEVENLABS_API_KEY to narrate new scripts.");
    }
    return { file, chars: 0, costUsd: 0, cached: true };
  }
}
