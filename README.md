# Present

A personal meditation app for iPhone. Each morning a new guided meditation is ready, written for you, narrated by a calm natural voice over gentle music, with real silence to breathe in. Sessions end with a reflection question and an optional private journal entry.

- **Themes:** presence, gratitude, stress relief, sleep, family connection, letting go of work, slowing down
- **Lengths:** 5, 10, 15 or 20 minutes. The audio is *exactly* that long.
- **Today · Library · Settings.** No streaks, no clutter.

| | |
|---|---|
| `ios/` | Native SwiftUI iPhone app (iOS 17+). Two-stem player (voice and music with independent volumes), background and lock-screen playback, offline downloads, on-device journal, voice previews, Suno uploads. |
| `server/` | Node 22 + TypeScript backend. Daily scheduler, Claude script writing, ElevenLabs narration, ffmpeg mixing, spend limits, push notifications. |
| `docs/TOOLS.md` | How ElevenLabs, Suno, Lovable, "Astra" and Claude fit together, plus the Lovable prompt |
| `docs/COSTS.md` | Verified pricing and monthly estimates (≈ $15/month for daily 10-minute sessions) |
| `docs/API.md` | Backend API contract |
| `docs/TESTING.md` | What was tested, how, and what wasn't |
| **`SETUP.md`** | **Start here:** run the backend, install on your iPhone, connect |

## How a session is made

1. **Schedule.** At your "ready by" time minus 30 minutes, in your phone's time zone, the server creates exactly one daily session. A unique index makes duplicates impossible. Failures retry with backoff (1, 5, 15 min), and a crashed worker's job is picked up again once its lease expires.
2. **Script.** Claude writes an original script as short segments, each with a requested pause. It's given your themes, your optional profile, and the titles, openings and images of recent sessions so it doesn't repeat itself. Scripts that are too long are rejected *before* any narration is paid for.
3. **Voice.** ElevenLabs (`eleven_v4`) records each segment, with request stitching so the delivery stays consistent from line to line. Clips are cached.
4. **Timing.** Silence is fitted between the clips so the session is exactly 5, 10, 15 or 20 minutes, to the sample. Short pauses join sentences; long ones hold open practice.
5. **Mix.**
   - Voice is levelled to −19 LUFS.
   - Music is looped with crossfades and levelled to −25 LUFS.
   - Music is gently ducked about 7 dB under each phrase and faded in and out.
   - Both stems are delivered separately, so you control their volumes independently on the phone.
6. **Ready.** You get a push at your chosen time (or a local reminder on a free Apple ID). The app downloads the session for offline listening.

## Demo mode

With no API keys, everything still works, clearly labelled **Demo**:
- seven hand-written scripts, one per theme
- an offline open-source voice (Piper), *not* ElevenLabs
- original ambient music

The app also bundles a 5-minute demo session that plays with no server at all. Nothing simulated is ever presented as a live integration: `/api/status` and Settings → Server show live or demo for each provider.

## Quick start (Mac)
```bash
cd server && cp .env.example .env && npm install && npm run dev     # backend in demo mode
brew install xcodegen && cd ../ios && xcodegen generate && open Present.xcodeproj
```
Then follow [SETUP.md](SETUP.md) to put it on your iPhone and deploy the backend so it runs while your Mac sleeps.

## Tests
```bash
cd server && npm test          # backend: timing, scheduler, jobs, API, audio pipeline, provider wiring
```
CI (`.github/workflows/ci.yml`) also builds the Docker image and runs the iOS unit and UI tests on an iPhone simulator against a demo backend. Screenshots from the UI tests are uploaded as an artifact.
