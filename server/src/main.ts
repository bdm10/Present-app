import { loadConfig } from "./config.js";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createProviders } from "./providers/index.js";
import { JobRunner } from "./jobs.js";
import { Scheduler } from "./scheduler.js";
import { ApnsNotifier } from "./push/apns.js";

const cfg = loadConfig();
const db = openDb(cfg.dataDir);
const providers = createProviders(cfg, db);
const notifier = new ApnsNotifier(cfg, db);

// Fastify's logger is used by the pipeline too; create the app first.
const placeholderLog = { info: () => {}, warn: () => {} };
const ctx = { cfg, db, providers, log: placeholderLog as { info: (o: object, m?: string) => void; warn: (o: object, m?: string) => void } };
const runner = new JobRunner(ctx);
const scheduler = new Scheduler(cfg, db, runner, notifier, () => providers.voice.defaultVoiceId());
const app = await buildApp({ cfg, db, providers, runner, scheduler, notifier, logger: true });
ctx.log = {
  info: (o, m) => app.log.info(o, m),
  warn: (o, m) => app.log.warn(o, m),
};

app.log.info(
  {
    script: `${providers.script.mode} (${providers.script.name})`,
    voice: `${providers.voice.mode} (${providers.voice.name})`,
    push: notifier.configured ? "configured" : "not configured",
  },
  "Present server starting",
);
if (providers.note) app.log.warn(providers.note);
if (cfg.appTokenGenerated) {
  app.log.warn(`No APP_TOKEN set. Using a generated token stored in ${cfg.dataDir}/app-token.txt (set APP_TOKEN in production).`);
}

await app.listen({ port: cfg.port, host: cfg.host });
runner.start();
scheduler.start();

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, async () => {
    scheduler.stop();
    runner.stop();
    await app.close();
    db.close();
    process.exit(0);
  });
}
