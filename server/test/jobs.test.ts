import { describe, expect, it } from "vitest";
import { JobRunner } from "../src/jobs.js";
import { UserFacingError } from "../src/pipeline.js";
import { createSessionWithJob, getSessionRow } from "../src/sessions.js";
import { SpendLimitError } from "../src/spend.js";
import { testEnv } from "./helpers.js";

function makeSession(db: ReturnType<typeof testEnv>["db"]) {
  return createSessionWithJob(db, { kind: "on_demand", localDate: "2026-10-17", theme: "presence", durationMinutes: 5 })!;
}
const job = (db: ReturnType<typeof testEnv>["db"], sessionId: string) =>
  db.prepare("SELECT * FROM jobs WHERE session_id = ?").get(sessionId) as { status: string; attempts: number; next_attempt_at: string; last_error: string };

describe("JobRunner", () => {
  it("marks the job done on success", async () => {
    const env = testEnv();
    const s = makeSession(env.db);
    const runner = new JobRunner(env.ctx, async (ctx, id) => {
      ctx.db.prepare("UPDATE sessions SET status = 'ready' WHERE id = ?").run(id);
    });
    await runner.drain();
    expect(job(env.db, s.id).status).toBe("done");
    expect(getSessionRow(env.db, s.id)!.status).toBe("ready");
  });

  it("retries a transient failure with backoff, then succeeds", async () => {
    const env = testEnv();
    const s = makeSession(env.db);
    let calls = 0;
    const runner = new JobRunner(env.ctx, async (ctx, id) => {
      calls++;
      if (calls === 1) throw new Error("ElevenLabs 503");
      ctx.db.prepare("UPDATE sessions SET status = 'ready' WHERE id = ?").run(id);
    });
    await runner.drain();
    let j = job(env.db, s.id);
    expect(j.status).toBe("queued");
    expect(j.attempts).toBe(1);
    expect(new Date(j.next_attempt_at).getTime()).toBeGreaterThan(Date.now() + 50_000);
    expect(getSessionRow(env.db, s.id)!.status_detail).toMatch(/trying again/);
    // Not due yet: draining again must not run it.
    await runner.drain();
    expect(calls).toBe(1);
    env.db.prepare("UPDATE jobs SET next_attempt_at = ?").run(new Date(Date.now() - 1000).toISOString());
    await runner.drain();
    j = job(env.db, s.id);
    expect(j.status).toBe("done");
    expect(j.attempts).toBe(2);
  });

  it("gives up after MAX_JOB_ATTEMPTS and shows a gentle message", async () => {
    const env = testEnv({ MAX_JOB_ATTEMPTS: "2" });
    const s = makeSession(env.db);
    const runner = new JobRunner(env.ctx, async () => {
      throw new Error("socket hang up");
    });
    await runner.drain();
    env.db.prepare("UPDATE jobs SET next_attempt_at = ?").run(new Date(Date.now() - 1000).toISOString());
    await runner.drain();
    expect(job(env.db, s.id).status).toBe("failed");
    const row = getSessionRow(env.db, s.id)!;
    expect(row.status).toBe("failed");
    expect(row.error).toMatch(/couldn't be prepared/);
    expect(row.error).not.toMatch(/socket/);
  });

  it("does not retry spending-limit failures and explains them", async () => {
    const env = testEnv();
    const s = makeSession(env.db);
    const runner = new JobRunner(env.ctx, async () => {
      throw new UserFacingError("This month's spending limit ($15.00) would be exceeded", false);
    });
    await runner.drain();
    expect(job(env.db, s.id).status).toBe("failed");
    expect(getSessionRow(env.db, s.id)!.error).toMatch(/spending limit/);
    const runner2 = new JobRunner(env.ctx, async () => {
      throw new SpendLimitError("limit");
    });
    const s2 = makeSession(env.db);
    await runner2.drain();
    expect(job(env.db, s2.id).status).toBe("failed");
  });

  it("recovers a job whose worker died mid-run (expired lease)", async () => {
    const env = testEnv();
    const s = makeSession(env.db);
    env.db.prepare("UPDATE jobs SET status = 'running', attempts = 1, lease_until = ?").run(new Date(Date.now() - 1000).toISOString());
    const runner = new JobRunner(env.ctx, async (ctx, id) => {
      ctx.db.prepare("UPDATE sessions SET status = 'ready' WHERE id = ?").run(id);
    });
    await runner.drain();
    expect(job(env.db, s.id).status).toBe("done");
  });

  it("does not run a job that another worker holds a live lease on", async () => {
    const env = testEnv();
    makeSession(env.db);
    env.db.prepare("UPDATE jobs SET status = 'running', lease_until = ?").run(new Date(Date.now() + 600_000).toISOString());
    let calls = 0;
    const runner = new JobRunner(env.ctx, async () => {
      calls++;
    });
    await runner.drain();
    expect(calls).toBe(0);
  });
});
