# Estimated running costs

Prices were checked on 17 October 2026. Some ElevenLabs figures could only be confirmed from secondary sources (marked ⚠︎). Re-check the linked pages before relying on them. The server's spending limit (`MONTHLY_SPEND_LIMIT_USD`, default $15) caps the AI costs either way.

## Per session

| | 5 min | 10 min | 15 min | 20 min |
|---|---|---|---|---|
| Spoken words (upper bound) | 280 | 460 | 580 | 700 |
| ElevenLabs `eleven_v4` narration at $0.08 / 1k characters ⚠︎ | ≈ $0.13 | ≈ $0.21 | ≈ $0.26 | ≈ $0.32 |
| Claude `claude-opus-5-5` script ($4 in / $20 out per M tokens) | ≈ $0.05–0.09 | ≈ $0.06–0.10 | ≈ $0.07–0.11 | ≈ $0.08–0.12 |
| **Total** | **≈ $0.20** | **≈ $0.30** | **≈ $0.36** | **≈ $0.43** |

- A script uses about 3k input tokens and 2–4k output tokens, including the model's thinking. Switching to `ANTHROPIC_MODEL=claude-sonnet-5-5` ($2 / $10) halves the script cost; `claude-haiku-5-5` makes it almost free, but the writing quality drops.
- Narration is cached. A retried job doesn't pay twice for lines it already recorded, and voice previews are generated once per voice.
- Demo mode costs nothing.

## Per month

Assumes one 10-minute daily session plus about 8 extra sessions a month.

| Item | Monthly | Notes |
|---|---|---|
| Claude API | ≈ $3 | 38 scripts |
| ElevenLabs API | ≈ $8 | ≈ 100k characters. Pay-as-you-go API pricing ⚠︎. Alternatively the Creator plan ($22/month, 121k credits) |
| Hosting (Fly.io `shared-cpu-1x`, 512 MB, 3 GB volume) | ≈ $4.15 | Must stay running for the scheduler. Railway Hobby ≈ $5, Render Starter + disk ≈ $7.75 |
| **Total** | **≈ $15/month** | |

One-off or optional costs:

| Item | Cost | Needed for |
|---|---|---|
| Apple Developer Program | $99 / year | Push notifications, TestFlight, and installs that don't expire every 7 days. Without it, a free Apple ID works from Xcode with a weekly re-install. |
| Suno Pro / Premier | $10 / $30 per month | Only if you want commercial rights or more downloads. Free tracks are fine for your own private listening. |
| GitHub Actions (iOS job) | Free tier: 2,000 min/month on private repos | macOS minutes count 10×. One iOS CI run is about 15–20 minutes, so roughly 150–200 of those minutes. |

## Storage

A 10-minute session is about 13 MB on the server (voice 64 kbps mono plus music 112 kbps stereo AAC). With `AUDIO_RETENTION_DAYS=60` (the default), audio for non-favourite sessions older than 60 days is removed from the server. Copies you've downloaded to the phone keep playing, and the library keeps the title, transcript and reflection question. A 3 GB volume is plenty.

## Sources
- ElevenLabs API pricing: https://elevenlabs.io/pricing/api · plans: https://elevenlabs.io/pricing
- Claude pricing: https://platform.claude.com/docs/en/about-claude/pricing
- Fly.io: https://fly.io/docs/about/pricing/ · Railway: https://docs.railway.com/pricing/plans · Render: https://render.com/pricing
- Apple Developer Program: https://developer.apple.com/programs/whats-included/
- GitHub Actions minutes: https://docs.github.com/en/billing/reference/actions-runner-pricing
