# Present — Backend API contract

Base URL: e.g. `https://present-yourname.fly.dev`. All JSON is camelCase. All `/api/*`
routes require `Authorization: Bearer <APP_TOKEN>`; a missing or wrong token returns `401`.
`GET /health` is unauthenticated and returns `{ "ok": true }`.

Errors: `{ "error": { "code": "string", "message": "human readable" } }` with a 4xx/5xx status.
Notable codes: `spend_limit` (402), `not_found` (404), `invalid` (400), `busy` (409).

Dates: `localDate` is `YYYY-MM-DD` in the user's time zone. Timestamps are ISO-8601 UTC strings.

## Types

```ts
type Theme = "presence" | "gratitude" | "stress" | "sleep" | "family" | "letting-go-of-work" | "slowing-down";
type Duration = 5 | 10 | 15 | 20;               // minutes
type SessionStatus = "queued" | "generating" | "ready" | "failed";
type ProviderMode = "live" | "demo";

interface Session {
  id: string;                    // e.g. "ses_8f3k2..."
  kind: "daily" | "on_demand";
  localDate: string;             // YYYY-MM-DD in user's zone when created
  createdAt: string;
  status: SessionStatus;
  statusDetail: string | null;   // e.g. "Writing script", "Recording voice", error text when failed
  theme: Theme;
  durationMinutes: Duration;
  title: string | null;          // null until script exists
  summary: string | null;        // one gentle sentence describing the session
  reflectionQuestion: string | null;
  durationSeconds: number | null;// exact length of both stems
  favorite: boolean;
  demo: boolean;                 // true if ANY part used demo providers
  providers: { script: string; voice: string; music: string } | null; // e.g. {script:"anthropic:claude-sonnet-…", voice:"elevenlabs:eleven_v3:<voiceId>", music:"builtin:warm-pad"}
  voiceName: string | null;
  musicTitle: string | null;
  audio: null | {
    voiceUrl: string;            // relative: /api/sessions/{id}/audio/voice.m4a
    musicUrl: string;            // relative: /api/sessions/{id}/audio/music.m4a
    voiceBytes: number;
    musicBytes: number;
  };
  transcript: { text: string; startSeconds: number }[] | null; // speech segments with start times
}

interface Settings {
  timeZone: string;              // IANA, e.g. "Europe/Madrid". App sends device zone on launch.
  dailyEnabled: boolean;
  dailyTime: string;             // "HH:mm" local — session should be READY by this time
  defaultDurationMinutes: Duration;
  themes: Theme[];               // rotation pool for daily sessions (>=1)
  voiceId: string;               // provider voice id
  musicTrackId: string | "auto"; // "auto" = rotate through enabled tracks
  notifyWhenReady: boolean;
  profile: {
    name: string;                // optional, "" if unset
    lovedOnes: string;           // free text, e.g. "my partner Sam and our two kids"
    context: string;             // free text, e.g. "I run a busy team and find evenings hard to switch off"
  };
}

interface Status {
  version: string;
  providers: {
    script: { mode: ProviderMode; name: string; detail: string };
    voice:  { mode: ProviderMode; name: string; detail: string };
    music:  { mode: ProviderMode; name: string; detail: string };
    push:   { configured: boolean; detail: string };
  };
  spend: { monthUsd: number; monthLimitUsd: number; dailyOnDemandCount: number; dailyOnDemandLimit: number };
  scheduler: { nextRunAt: string | null; lastError: string | null };
}

interface Voice {
  id: string;
  name: string;
  description: string;          // e.g. "Warm, low, British"
  provider: "elevenlabs" | "demo";
  previewUrl: string;            // relative: /api/voices/{id}/preview.m4a (generated & cached; meditation text)
}

interface MusicTrack {
  id: string;
  title: string;
  source: "builtin" | "upload" | "generated";
  license: string;               // e.g. "Original, CC0 (Present)" or "Uploaded by you (Suno)"
  durationSeconds: number;
  enabled: boolean;
  previewUrl: string;            // relative: /api/music/{id}/audio.m4a
}
```

## Endpoints

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/status` | – | `Status` |
| GET | `/api/today` | – | `{ session: Session \| null, nextDailyAt: string \| null }` — today's daily session (any status) else null |
| GET | `/api/sessions?favorites=true&limit=50&before=<createdAt>` | – | `{ sessions: Session[] }` newest first |
| GET | `/api/sessions/:id` | – | `Session` |
| POST | `/api/sessions` | `{ theme?: Theme, durationMinutes?: Duration }` | `202 Session` (status queued). Poll `GET /api/sessions/:id` every ~3 s. |
| PATCH | `/api/sessions/:id` | `{ favorite: boolean }` | `Session` |
| DELETE | `/api/sessions/:id` | – | `204` (deletes record + audio) |
| GET | `/api/sessions/:id/audio/voice.m4a` | – | AAC audio (Range supported) |
| GET | `/api/sessions/:id/audio/music.m4a` | – | AAC audio (Range supported) |
| GET | `/api/settings` | – | `Settings` |
| PUT | `/api/settings` | partial `Settings` (any subset of fields; `profile` may be partial) | `Settings` |
| GET | `/api/voices` | – | `{ voices: Voice[] }` |
| GET | `/api/voices/:id/preview.m4a` | – | AAC audio (~12 s sample, cached) |
| GET | `/api/music` | – | `{ tracks: MusicTrack[] }` |
| POST | `/api/music` | `multipart/form-data` with `file` (mp3/m4a/wav, ≤ 40 MB) and optional `title` | `201 MusicTrack` |
| PATCH | `/api/music/:id` | `{ enabled?: boolean, title?: string }` | `MusicTrack` |
| DELETE | `/api/music/:id` | – | `204` (uploads only; builtin → 400) |
| GET | `/api/music/:id/audio.m4a` | – | AAC audio |
| POST | `/api/devices` | `{ apnsToken: string, environment: "sandbox" \| "production" }` | `204` |
| DELETE | `/api/data` | `{ confirm: "DELETE" }` | `204` — wipes sessions, audio, scripts, uploads, profile, devices and caches; settings reset. The anonymous spend ledger (dates + amounts) is kept so spending limits still apply |

## Audio contract

- Two stems per session with **identical duration** (`durationSeconds`), AAC in `.m4a`, 44.1 kHz.
  - `voice.m4a`: mono, speech with silences baked in, loudness-normalised (~-19 LUFS).
  - `music.m4a`: stereo, already faded in/out and gently ducked under the voice (~-30 LUFS).
- The client plays both sample-aligned from t=0 and applies its own per-stem volume
  (defaults voice 1.0, music 0.6). Seeking applies the same time to both.

## Push payload (APNs)

```json
{ "aps": { "alert": { "title": "Today's session is ready", "body": "…" }, "sound": "default" },
  "sessionId": "ses_…" }
```
