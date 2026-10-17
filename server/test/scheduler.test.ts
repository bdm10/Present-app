import { DateTime } from "luxon";
import { describe, expect, it } from "vitest";
import { Scheduler, dailyWindow, nextDailyReadyAt, nextTheme } from "../src/scheduler.js";
import { MemoryNotifier } from "../src/push/apns.js";
import { updateSettings, defaultSettings } from "../src/settings.js";
import type { JobRunner } from "../src/jobs.js";
import { testEnv } from "./helpers.js";

function setup(now: { v: DateTime }, settings: Parameters<typeof updateSettings>[2] = {}) {
  const env = testEnv();
  updateSettings(env.db, "demo-wren", { timeZone: "Europe/Madrid", dailyTime: "07:00", dailyEnabled: true, ...settings });
  let kicks = 0;
  const runner = { kick: () => kicks++ } as unknown as JobRunner;
  const notifier = new MemoryNotifier();
  const scheduler = new Scheduler(env.cfg, env.db, runner, notifier, () => "demo-wren", () => now.v);
  return { ...env, scheduler, notifier, kicks: () => kicks };
}

const madrid = (iso: string) => DateTime.fromISO(iso, { zone: "Europe/Madrid" }).toUTC();

describe("daily window", () => {
  it("uses the user's local zone, with generation starting before the ready time", () => {
    const s = { ...defaultSettings("v"), timeZone: "America/Los_Angeles", dailyTime: "06:30" };
    const w = dailyWindow(DateTime.fromISO("2026-10-17T12:00:00Z"), s, { dailyLeadMinutes: 30, catchUpHours: 12 });
    expect(w.localDate).toBe("2026-10-17");
    expect(w.readyAt.toUTC().toISO()).toBe("2026-10-17T13:30:00.000Z"); // PDT = UTC-7
    expect(w.startAt.toUTC().toISO()).toBe("2026-10-17T13:00:00.000Z");
  });

  it("handles the spring-forward gap without skipping the day", () => {
    const s = { ...defaultSettings("v"), timeZone: "Europe/Madrid", dailyTime: "02:30" };
    // 2027-03-28: clocks go 02:00 -> 03:00 in Madrid; 02:30 does not exist.
    const w = dailyWindow(madrid("2027-03-28T12:00:00"), s, { dailyLeadMinutes: 30, catchUpHours: 12 });
    expect(w.localDate).toBe("2027-03-28");
    expect(w.readyAt.isValid).toBe(true);
  });

  it("computes the next ready time across midnight", () => {
    const s = { ...defaultSettings("v"), timeZone: "Europe/Madrid", dailyTime: "07:00" };
    const next = nextDailyReadyAt(madrid("2026-10-17T21:00:00"), s, { dailyLeadMinutes: 30, catchUpHours: 12 })!;
    expect(next.setZone("Europe/Madrid").toISO()).toBe("2026-10-18T07:00:00.000+02:00");
  });
});

describe("Scheduler.tick", () => {
  it("waits until the app has saved settings (and so the user's time zone)", async () => {
    const env = testEnv();
    const runner = { kick: () => {} } as unknown as JobRunner;
    const scheduler = new Scheduler(env.cfg, env.db, runner, new MemoryNotifier(), () => "demo-wren", () => madrid("2026-10-17T07:30:00"));
    expect((await scheduler.tick()).created).toBeNull();
  });

  it("does nothing before the generation window", async () => {
    const now = { v: madrid("2026-10-17T06:00:00") };
    const t = setup(now);
    const r = await t.scheduler.tick();
    expect(r.created).toBeNull();
    expect(t.kicks()).toBe(0);
  });

  it("creates exactly one daily session per local day, however often it ticks", async () => {
    const now = { v: madrid("2026-10-17T06:35:00") };
    const t = setup(now);
    const first = await t.scheduler.tick();
    expect(first.created?.kind).toBe("daily");
    expect(first.created?.local_date).toBe("2026-10-17");
    for (let i = 0; i < 5; i++) expect((await t.scheduler.tick()).created).toBeNull();
    const count = t.db.prepare("SELECT COUNT(*) AS n FROM sessions WHERE kind = 'daily'").get() as { n: number };
    expect(count.n).toBe(1);
    const jobs = t.db.prepare("SELECT COUNT(*) AS n FROM jobs").get() as { n: number };
    expect(jobs.n).toBe(1);
    expect(t.kicks()).toBe(1);
  });

  it("catches up after downtime within the catch-up window, but skips a long-missed day", async () => {
    const now = { v: madrid("2026-10-17T11:00:00") };
    const t = setup(now);
    expect((await t.scheduler.tick()).created).not.toBeNull();
    const now2 = { v: madrid("2026-10-17T21:00:00") }; // 14h after 07:00 > CATCH_UP_HOURS (12)
    const t2 = setup(now2);
    expect((await t2.scheduler.tick()).created).toBeNull();
  });

  it("respects dailyEnabled = false", async () => {
    const now = { v: madrid("2026-10-17T06:45:00") };
    const t = setup(now, { dailyEnabled: false });
    expect((await t.scheduler.tick()).created).toBeNull();
  });

  it("notifies once, at the ready time, when the session is ready", async () => {
    const now = { v: madrid("2026-10-17T06:31:00") };
    const t = setup(now);
    const { created } = await t.scheduler.tick();
    t.db.prepare("UPDATE sessions SET status = 'ready', title = 'Test' WHERE id = ?").run(created!.id);
    expect((await t.scheduler.tick()).notified).toBe(false); // ready early: wait for 07:00
    now.v = madrid("2026-10-17T07:00:10");
    expect((await t.scheduler.tick()).notified).toBe(true);
    expect((await t.scheduler.tick()).notified).toBe(false);
    expect(t.notifier.sent).toHaveLength(1);
    expect(t.notifier.sent[0].title).toBe("Today's session is ready");
    expect(t.notifier.sent[0].sessionId).toBe(created!.id);
  });

  it("tells the user when today's session failed", async () => {
    const now = { v: madrid("2026-10-17T06:31:00") };
    const t = setup(now);
    const { created } = await t.scheduler.tick();
    t.db.prepare("UPDATE sessions SET status = 'failed' WHERE id = ?").run(created!.id);
    now.v = madrid("2026-10-17T07:05:00");
    expect((await t.scheduler.tick()).notified).toBe(true);
    expect(t.notifier.sent[0].title).toMatch(/couldn't be prepared/);
  });

  it("does not notify when the user turned notifications off", async () => {
    const now = { v: madrid("2026-10-17T07:10:00") };
    const t = setup(now, { notifyWhenReady: false });
    const { created } = await t.scheduler.tick();
    t.db.prepare("UPDATE sessions SET status = 'ready' WHERE id = ?").run(created!.id);
    expect((await t.scheduler.tick()).notified).toBe(false);
    expect(t.notifier.sent).toHaveLength(0);
  });

  it("rotates themes, least recently used first", async () => {
    const t = setup({ v: madrid("2026-10-17T06:31:00") }, { themes: ["presence", "gratitude", "family"] });
    expect(nextTheme(t.db, ["presence", "gratitude", "family"])).toBe("presence");
    t.db.prepare(
      "INSERT INTO sessions (id, kind, local_date, created_at, status, theme, duration_minutes) VALUES ('ses_a', 'daily', '2026-10-15', '2026-10-15T05:00:00Z', 'ready', 'presence', 10)",
    ).run();
    t.db.prepare(
      "INSERT INTO sessions (id, kind, local_date, created_at, status, theme, duration_minutes) VALUES ('ses_b', 'daily', '2026-10-16', '2026-10-16T05:00:00Z', 'ready', 'gratitude', 10)",
    ).run();
    expect(nextTheme(t.db, ["presence", "gratitude", "family"])).toBe("family");
  });
});
