import { z } from "zod";
import { DateTime } from "luxon";
import { DB, DURATIONS, THEMES, kvGet, kvSet, type Duration, type Theme } from "./db.js";

export interface Settings {
  timeZone: string;
  dailyEnabled: boolean;
  dailyTime: string;
  defaultDurationMinutes: Duration;
  themes: Theme[];
  voiceId: string;
  musicTrackId: string;
  notifyWhenReady: boolean;
  profile: { name: string; lovedOnes: string; context: string };
}

export function defaultSettings(defaultVoiceId: string): Settings {
  return {
    timeZone: "UTC",
    dailyEnabled: true,
    dailyTime: "07:00",
    defaultDurationMinutes: 10,
    themes: ["presence", "gratitude", "slowing-down", "family", "letting-go-of-work"],
    voiceId: defaultVoiceId,
    musicTrackId: "auto",
    notifyWhenReady: true,
    profile: { name: "", lovedOnes: "", context: "" },
  };
}

export const durationSchema = z
  .number()
  .refine((d): d is Duration => (DURATIONS as readonly number[]).includes(d), "Duration must be 5, 10, 15 or 20")
  .transform((d) => d as Duration);

const zone = z.string().refine((tz) => DateTime.now().setZone(tz).isValid, "Unknown IANA time zone");

export const settingsPatchSchema = z
  .object({
    timeZone: zone,
    dailyEnabled: z.boolean(),
    dailyTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, "Use HH:mm"),
    defaultDurationMinutes: durationSchema,
    themes: z.array(z.enum(THEMES as [Theme, ...Theme[]])).min(1).max(THEMES.length),
    voiceId: z.string().min(1).max(100),
    musicTrackId: z.string().min(1).max(100),
    notifyWhenReady: z.boolean(),
    profile: z
      .object({
        name: z.string().max(60),
        lovedOnes: z.string().max(400),
        context: z.string().max(800),
      })
      .partial(),
  })
  .partial()
  .strict();

export type SettingsPatch = z.infer<typeof settingsPatchSchema>;

export function getSettings(db: DB, defaultVoiceId: string): Settings {
  const stored = kvGet<Partial<Settings>>(db, "settings");
  const base = defaultSettings(defaultVoiceId);
  if (!stored) return base;
  return { ...base, ...stored, profile: { ...base.profile, ...(stored.profile ?? {}) } };
}

export function updateSettings(db: DB, defaultVoiceId: string, patch: SettingsPatch): Settings {
  const current = getSettings(db, defaultVoiceId);
  const next: Settings = {
    ...current,
    ...patch,
    themes: patch.themes ? Array.from(new Set(patch.themes)) : current.themes,
    profile: { ...current.profile, ...(patch.profile ?? {}) },
  } as Settings;
  kvSet(db, "settings", next);
  return next;
}
