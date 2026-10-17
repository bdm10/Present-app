import { DB, JobRow, nowIso, tx } from "./db.js";
import { generateSession, PipelineContext, UserFacingError } from "./pipeline.js";
import { getSessionRow, setStatus } from "./sessions.js";
import { SpendLimitError } from "./spend.js";

const LEASE_MS = 20 * 60 * 1000;
/** Minutes to wait before attempt 2, 3, 4, ... */
const BACKOFF_MINUTES = [1, 5, 15, 30, 60];

export type GenerateFn = (ctx: PipelineContext, sessionId: string) => Promise<void>;

/**
 * Runs generation jobs one at a time. Jobs are leased so a crash mid-generation is
 * picked up again once the lease expires; failures retry with backoff.
 */
export class JobRunner {
  private timer: NodeJS.Timeout | null = null;
  private current: Promise<void> | null = null;
  private kicked = false;
  lastError: string | null = null;

  constructor(
    private ctx: PipelineContext,
    private generate: GenerateFn = generateSession,
  ) {}

  start(intervalMs = 3000): void {
    // Anything left "running" from a previous process can't still be running.
    this.ctx.db.prepare("UPDATE jobs SET status = 'queued', lease_until = NULL WHERE status = 'running'").run();
    this.timer = setInterval(() => void this.drain(), intervalMs);
    void this.drain();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  kick(): void {
    void this.drain();
  }

  /** Processes due jobs until none are left. Resolves when the runner is idle. */
  drain(): Promise<void> {
    if (this.current) {
      this.kicked = true;
      return this.current;
    }
    const run = (async () => {
      do {
        this.kicked = false;
        let job: JobRow | undefined;
        while ((job = this.claim())) await this.run(job);
      } while (this.kicked);
    })();
    this.current = run;
    const clear = () => {
      if (this.current === run) this.current = null;
    };
    run.then(clear, clear);
    return run;
  }

  get isBusy(): boolean {
    return this.current !== null;
  }

  private claim(): JobRow | undefined {
    const db = this.ctx.db;
    return tx(db, () => {
      const now = nowIso();
      const job = db
        .prepare(
          `SELECT * FROM jobs
           WHERE (status = 'queued' AND next_attempt_at <= ?) OR (status = 'running' AND lease_until < ?)
           ORDER BY next_attempt_at LIMIT 1`,
        )
        .get(now, now) as unknown as JobRow | undefined;
      if (!job) return undefined;
      const lease = new Date(Date.now() + LEASE_MS).toISOString();
      db.prepare("UPDATE jobs SET status = 'running', lease_until = ?, attempts = attempts + 1, updated_at = ? WHERE id = ?").run(
        lease,
        now,
        job.id,
      );
      return { ...job, status: "running", attempts: job.attempts + 1, lease_until: lease };
    });
  }

  private async run(job: JobRow): Promise<void> {
    const { db, cfg, log } = this.ctx;
    if (!getSessionRow(db, job.session_id)) {
      db.prepare("DELETE FROM jobs WHERE id = ?").run(job.id);
      return;
    }
    try {
      setStatus(db, job.session_id, "generating", "Starting");
      await this.generate(this.ctx, job.session_id);
      db.prepare("UPDATE jobs SET status = 'done', lease_until = NULL, last_error = NULL, updated_at = ? WHERE id = ?").run(
        nowIso(),
        job.id,
      );
      this.lastError = null;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.lastError = message;
      const userFacing = err instanceof UserFacingError || err instanceof SpendLimitError;
      const retryable = !(err instanceof SpendLimitError) && !(err instanceof UserFacingError && !err.retryable);
      log.warn({ sessionId: job.session_id, attempt: job.attempts, err: message }, "generation failed");
      if (retryable && job.attempts < cfg.maxJobAttempts) {
        const waitMin = BACKOFF_MINUTES[Math.min(job.attempts - 1, BACKOFF_MINUTES.length - 1)];
        const next = new Date(Date.now() + waitMin * 60_000).toISOString();
        db.prepare("UPDATE jobs SET status = 'queued', lease_until = NULL, next_attempt_at = ?, last_error = ?, updated_at = ? WHERE id = ?").run(
          next,
          message.slice(0, 1000),
          nowIso(),
          job.id,
        );
        setStatus(db, job.session_id, "queued", `Something went wrong; trying again in ${waitMin} minute${waitMin === 1 ? "" : "s"}`);
      } else {
        db.prepare("UPDATE jobs SET status = 'failed', lease_until = NULL, last_error = ?, updated_at = ? WHERE id = ?").run(
          message.slice(0, 1000),
          nowIso(),
          job.id,
        );
        const friendly = userFacing ? message : "This session couldn't be prepared. You can try again from the Today screen.";
        db.prepare("UPDATE sessions SET status = 'failed', status_detail = NULL, error = ? WHERE id = ?").run(friendly, job.session_id);
      }
    }
  }
}
