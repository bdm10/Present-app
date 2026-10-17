import { DateTime } from "luxon";
import type { Config } from "./config.js";
import { DB, nowIso, type Duration } from "./db.js";
import { WORD_BUDGET } from "./providers/script/prompt.js";

export class SpendLimitError extends Error {
  readonly code = "spend_limit";
}

export function monthStartIso(timeZone: string): string {
  return DateTime.now().setZone(timeZone).startOf("month").toUTC().toISO()!;
}

export function monthSpendUsd(db: DB, timeZone: string): number {
  const row = db.prepare("SELECT COALESCE(SUM(usd), 0) AS total FROM spend WHERE ts >= ?").get(monthStartIso(timeZone)) as {
    total: number;
  };
  return Math.round(row.total * 10000) / 10000;
}

export function recordSpend(db: DB, provider: string, units: number, usd: number, sessionId: string | null, note: string): void {
  if (usd <= 0 && units <= 0) return;
  db.prepare("INSERT INTO spend (ts, provider, units, usd, session_id, note) VALUES (?, ?, ?, ?, ?, ?)").run(
    nowIso(),
    provider,
    units,
    usd,
    sessionId,
    note,
  );
}

/** A deliberately pessimistic estimate of one session's cost, used before spending anything. */
export function estimateSessionUsd(cfg: Config, durationMinutes: Duration, scriptLive: boolean, voiceLive: boolean): number {
  let usd = 0;
  if (scriptLive) {
    // ~4k input tokens and up to ~8k output tokens (including thinking), with one possible retry.
    usd += 1.5 * ((4000 / 1e6) * cfg.anthropicUsdPerMTokIn + (8000 / 1e6) * cfg.anthropicUsdPerMTokOut);
  }
  if (voiceLive) {
    const chars = WORD_BUDGET[durationMinutes][1] * 6.5;
    usd += (chars / 1000) * cfg.elevenLabsUsdPer1kChars;
  }
  return usd;
}

export function assertWithinBudget(cfg: Config, db: DB, timeZone: string, estimateUsd: number): void {
  if (estimateUsd <= 0) return;
  const spent = monthSpendUsd(db, timeZone);
  if (spent + estimateUsd > cfg.monthlySpendLimitUsd) {
    throw new SpendLimitError(
      `This month's spending limit ($${cfg.monthlySpendLimitUsd.toFixed(2)}) would be exceeded ` +
        `(spent $${spent.toFixed(2)}, this session needs up to $${estimateUsd.toFixed(2)}). ` +
        `Raise MONTHLY_SPEND_LIMIT_USD on the server or wait until next month.`,
    );
  }
}

export function onDemandCountToday(db: DB, timeZone: string): number {
  const today = DateTime.now().setZone(timeZone).toISODate()!;
  const row = db
    .prepare("SELECT COUNT(*) AS n FROM sessions WHERE kind = 'on_demand' AND local_date = ?")
    .get(today) as { n: number };
  return row.n;
}
