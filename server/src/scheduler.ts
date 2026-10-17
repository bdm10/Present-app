import { DateTime } from "luxon";
import type { Config } from "./config.js";
import { DB, SessionRow, kvGet, nowIso, type Theme } from "./db.js";
import type { JobRunner } from "./jobs.js";
import type { Notifier } from "./push/apns.js";
import { archiveOldAudio, createSessionWithJob, dailySessionFor } from "./sessions.js";
import { getSettings, type Settings } from "./settings.js";

export interface DailyWindow {
  localDate: string;
  /** When the session should be ready (the user's chosen time today). */
  readyAt: DateTime;
  /** When generation starts (readyAt minus lead time). */
  startAt: DateTime;
  /** After this, a missed day is skipped rather than generated late. */
  giveUpAt: DateTime;
}

/** The daily window for the local date that `now` falls on, in the user's zone. DST-safe via Luxon. */
export function dailyWindow(now: DateTime, settings: Settings, cfg: Pick<Config, "dailyLeadMinutes" | "catchUpHours">): DailyWindow {
  const local = now.setZone(settings.timeZone);
  const [h, m] = settings.dailyTime.split(":").map(Number);
  // For a time that doesn't exist (spring-forward gap), Luxon moves it forward.
  const readyAt = local.set({ hour: h, minute: m, second: 0, millisecond: 0 });
  return {
    localDate: local.toISODate()!,
    readyAt,
    startAt: readyAt.minus({ minutes: cfg.dailyLeadMinutes }),
    giveUpAt: readyAt.plus({ hours: cfg.catchUpHours }),
  };
}

export function nextDailyReadyAt(now: DateTime, settings: Settings, cfg: Pick<Config, "dailyLeadMinutes" | "catchUpHours">): DateTime | null {
  if (!settings.dailyEnabled) return null;
  const w = dailyWindow(now, settings, cfg);
  if (now < w.readyAt) return w.readyAt;
  return dailyWindow(now.setZone(settings.timeZone).plus({ days: 1 }).startOf("day").plus({ hours: 12 }), settings, cfg).readyAt;
}

/** Least recently used theme from the user's rotation. */
export function nextTheme(db: DB, themes: Theme[]): Theme {
  let best: Theme = themes[0];
  let bestAt = "￿";
  for (const t of themes) {
    const row = db.prepare("SELECT MAX(created_at) AS at FROM sessions WHERE kind = 'daily' AND theme = ?").get(t) as {
      at: string | null;
    };
    const at = row.at ?? "";
    if (at < bestAt) {
      best = t;
      bestAt = at;
    }
  }
  return best;
}

export class Scheduler {
  private timer: NodeJS.Timeout | null = null;
  private lastCleanup = 0;
  lastError: string | null = null;

  constructor(
    private cfg: Config,
    private db: DB,
    private runner: JobRunner,
    private notifier: Notifier,
    private defaultVoiceId: () => string,
    private clock: () => DateTime = () => DateTime.utc(),
  ) {}

  start(intervalMs = 30_000): void {
    this.timer = setInterval(() => void this.tick(), intervalMs);
    void this.tick();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  nextRunAt(): string | null {
    const settings = getSettings(this.db, this.defaultVoiceId());
    const next = nextDailyReadyAt(this.clock(), settings, this.cfg);
    return next ? next.minus({ minutes: this.cfg.dailyLeadMinutes }).toUTC().toISO() : null;
  }

  /** One scheduling pass: create today's session when due, and send any notifications that are due. */
  async tick(): Promise<{ created: SessionRow | null; notified: boolean }> {
    let created: SessionRow | null = null;
    let notified = false;
    try {
      if (Date.now() - this.lastCleanup > 60 * 60 * 1000) {
        this.lastCleanup = Date.now();
        archiveOldAudio(this.db, this.cfg.dataDir, this.cfg.audioRetentionDays);
      }

      // Until the app has saved settings (including the phone's time zone), we don't know
      // when "morning" is, so nothing is scheduled.
      if (!kvGet(this.db, "settings")) return { created, notified };
      const settings = getSettings(this.db, this.defaultVoiceId());
      const now = this.clock();
      const w = dailyWindow(now, settings, this.cfg);

      if (settings.dailyEnabled && now >= w.startAt && now <= w.giveUpAt && !dailySessionFor(this.db, w.localDate)) {
        created = createSessionWithJob(this.db, {
          kind: "daily",
          localDate: w.localDate,
          theme: nextTheme(this.db, settings.themes),
          durationMinutes: settings.defaultDurationMinutes,
        });
        if (created) this.runner.kick();
      }

      const today = dailySessionFor(this.db, w.localDate);
      if (today && !today.notified_at && now >= w.readyAt && (today.status === "ready" || today.status === "failed")) {
        if (settings.notifyWhenReady) {
          const msg =
            today.status === "ready"
              ? { title: "Today's session is ready", body: today.title ? `${today.title} · ${today.duration_minutes} minutes` : "Whenever you are.", sessionId: today.id }
              : { title: "Today's session couldn't be prepared", body: "Open Present to try again.", sessionId: today.id };
          await this.notifier.send(msg);
          notified = true;
        }
        this.db.prepare("UPDATE sessions SET notified_at = ? WHERE id = ?").run(nowIso(), today.id);
      }
      this.lastError = null;
    } catch (err) {
      this.lastError = err instanceof Error ? err.message : String(err);
    }
    return { created, notified };
  }
}
