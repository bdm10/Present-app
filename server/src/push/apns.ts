import crypto from "node:crypto";
import http2 from "node:http2";
import type { Config } from "../config.js";
import { DB } from "../db.js";

export interface PushMessage {
  title: string;
  body: string;
  sessionId?: string;
}

export interface Notifier {
  readonly configured: boolean;
  readonly detail: string;
  send(msg: PushMessage): Promise<{ sent: number; failed: number }>;
}

/** Sends alerts through Apple Push Notification service using token-based (.p8) auth. */
export class ApnsNotifier implements Notifier {
  private jwt: { token: string; at: number } | null = null;

  constructor(private cfg: Config, private db: DB) {}

  get configured(): boolean {
    return !!(this.cfg.apnsKeyId && this.cfg.apnsTeamId && this.cfg.apnsKeyP8 && this.cfg.apnsBundleId);
  }

  get detail(): string {
    return this.configured
      ? `Apple Push configured for ${this.cfg.apnsBundleId}`
      : "Apple Push not configured (needs a paid Apple Developer account). The app falls back to a local daily reminder.";
  }

  private bearer(): string {
    // Apple accepts a provider token for up to an hour; refresh every 50 minutes.
    if (this.jwt && Date.now() - this.jwt.at < 50 * 60 * 1000) return this.jwt.token;
    const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: this.cfg.apnsKeyId })).toString("base64url");
    const claims = Buffer.from(JSON.stringify({ iss: this.cfg.apnsTeamId, iat: Math.floor(Date.now() / 1000) })).toString(
      "base64url",
    );
    const signature = crypto
      .sign("sha256", Buffer.from(`${header}.${claims}`), { key: this.cfg.apnsKeyP8, dsaEncoding: "ieee-p1363" })
      .toString("base64url");
    this.jwt = { token: `${header}.${claims}.${signature}`, at: Date.now() };
    return this.jwt.token;
  }

  async send(msg: PushMessage): Promise<{ sent: number; failed: number }> {
    if (!this.configured) return { sent: 0, failed: 0 };
    const devices = this.db.prepare("SELECT token, environment FROM devices").all() as { token: string; environment: string }[];
    let sent = 0;
    let failed = 0;
    const payload = JSON.stringify({
      aps: { alert: { title: msg.title, body: msg.body }, sound: "default" },
      ...(msg.sessionId ? { sessionId: msg.sessionId } : {}),
    });
    for (const d of devices) {
      const host = d.environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
      try {
        const { status, body } = await post(host, `/3/device/${d.token}`, payload, {
          authorization: `bearer ${this.bearer()}`,
          "apns-topic": this.cfg.apnsBundleId,
          "apns-push-type": "alert",
          "apns-priority": "10",
        });
        if (status === 200) {
          sent++;
          this.db.prepare("UPDATE devices SET last_error = NULL WHERE token = ?").run(d.token);
        } else {
          failed++;
          if (status === 410 || body.includes("BadDeviceToken") || body.includes("Unregistered")) {
            this.db.prepare("DELETE FROM devices WHERE token = ?").run(d.token);
          } else {
            this.db.prepare("UPDATE devices SET last_error = ? WHERE token = ?").run(`${status} ${body}`.slice(0, 300), d.token);
          }
        }
      } catch (err) {
        failed++;
        this.db.prepare("UPDATE devices SET last_error = ? WHERE token = ?").run(String(err).slice(0, 300), d.token);
      }
    }
    return { sent, failed };
  }
}

function post(
  origin: string,
  path: string,
  body: string,
  headers: Record<string, string>,
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const client = http2.connect(origin);
    client.on("error", reject);
    const req = client.request({ ":method": "POST", ":path": path, "content-type": "application/json", ...headers });
    let status = 0;
    let data = "";
    req.setTimeout(15_000, () => {
      req.close();
      client.close();
      reject(new Error("APNs timeout"));
    });
    req.on("response", (h) => {
      status = Number(h[":status"]);
    });
    req.on("data", (c: Buffer) => (data += c.toString()));
    req.on("end", () => {
      client.close();
      resolve({ status, body: data });
    });
    req.on("error", (e) => {
      client.close();
      reject(e);
    });
    req.end(body);
  });
}

/** Used in tests and when push isn't configured: records what would have been sent. */
export class MemoryNotifier implements Notifier {
  readonly configured = true;
  readonly detail = "In-memory test notifier";
  readonly sent: PushMessage[] = [];
  async send(msg: PushMessage) {
    this.sent.push(msg);
    return { sent: 1, failed: 0 };
  }
}
