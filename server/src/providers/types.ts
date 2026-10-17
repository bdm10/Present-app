import type { Duration, Theme } from "../db.js";

export type ProviderMode = "live" | "demo";

export interface ScriptSegment {
  text: string;
  /** Requested silence after this segment, in seconds. Scaled later to fit the exact duration. */
  pauseAfterSeconds: number;
}

export interface MeditationScript {
  title: string;
  summary: string;
  segments: ScriptSegment[];
  reflectionQuestion: string;
  /** Key images/phrases used, remembered to avoid repeating them in future sessions. */
  motifs: string[];
}

export interface RecentSessionNote {
  title: string;
  theme: string;
  motifs: string[];
  opening: string;
}

export interface ScriptRequest {
  theme: Theme;
  durationMinutes: Duration;
  kind: "daily" | "on_demand";
  /** Human description of when the listener will hear it, e.g. "Saturday morning in October". */
  when: string;
  profile: { name: string; lovedOnes: string; context: string };
  recent: RecentSessionNote[];
  allowAudioTags: boolean;
  /** Feedback from a previous attempt (e.g. too long), used on retry. */
  feedback?: string;
}

export interface ScriptResult {
  script: MeditationScript;
  model: string;
  costUsd: number;
  usage?: { inputTokens: number; outputTokens: number };
}

export interface ScriptProvider {
  readonly name: string;
  readonly mode: ProviderMode;
  readonly detail: string;
  write(req: ScriptRequest): Promise<ScriptResult>;
}

export interface VoiceInfo {
  id: string;
  name: string;
  description: string;
}

export interface TtsRequest {
  voiceId: string;
  text: string;
  previousText?: string;
  nextText?: string;
  previousRequestIds?: string[];
}

export interface TtsResult {
  /** Path to the synthesised audio (any format ffmpeg can read). */
  file: string;
  requestId?: string;
  chars: number;
  costUsd: number;
  cached: boolean;
}

export interface VoiceProvider {
  readonly name: string;
  readonly mode: ProviderMode;
  readonly detail: string;
  readonly model: string;
  readonly supportsAudioTags: boolean;
  /** Whether consecutive requests can be stitched with previous_request_ids. */
  readonly supportsRequestStitching: boolean;
  listVoices(): Promise<VoiceInfo[]>;
  defaultVoiceId(): string;
  synthesize(req: TtsRequest): Promise<TtsResult>;
}

export const THEME_LABELS: Record<Theme, string> = {
  presence: "Presence",
  gratitude: "Gratitude",
  stress: "Stress relief",
  sleep: "Sleep",
  family: "Family connection",
  "letting-go-of-work": "Letting go of work",
  "slowing-down": "Slowing down",
};
