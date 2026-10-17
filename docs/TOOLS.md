# How the tools fit together

Facts were checked on 17 October 2026 against official docs where reachable (sources at the end).

```
         ┌──────────── your iPhone ────────────┐
         │  Present (native SwiftUI app)       │
         │  Today · Library · Settings         │
         │  2-stem player, lock screen, offline│
         │  private journal (never leaves it)  │
         └──────────────┬──────────────────────┘
                        │ HTTPS + access token
         ┌──────────────▼──────────────────────┐
         │  Present backend (Node, SQLite,     │
         │  ffmpeg) on Fly.io / Railway / Mac  │
         │  scheduler · jobs · spend limits    │
         └───┬──────────────┬──────────────┬───┘
             │              │              │
     Claude API      ElevenLabs API    Music library
     (writes the     (narrates each    (original CC0 tracks +
      script)         line, eleven_v4)  your Suno uploads)
```

| Tool | Role in Present | Can Claude Code operate it here? | Notes |
|---|---|---|---|
| **Claude Code** | Built and tested everything: backend, audio pipeline, scheduler, iOS app, CI | Yes | Owns integration and testing. |
| **Claude API** (`claude-opus-5-5` by default) | Writes each original script as structured JSON: segments, pause lengths, title, reflection question, motifs to avoid repeating | Yes, via your `ANTHROPIC_API_KEY` on the server | `ANTHROPIC_MODEL=claude-sonnet-5-5` roughly halves script cost. |
| **ElevenLabs** (`eleven_v4`) | Narration, one line at a time, with request stitching for consistent prosody. Real silence is inserted between lines, so pauses don't depend on any model feature. | Yes, via your `ELEVENLABS_API_KEY` on the server | See "ElevenLabs" below. |
| **Suno** | Your own background tracks | **No official public API** | Upload tracks in the app (Settings → Music). Three original ambient tracks ship as the fallback. |
| **Lovable** | Optional: visual design exploration | Not from this session (its MCP server isn't connected here) | Lovable makes web apps, not native iOS. Prompt and hand-back steps below. |
| **"Astra"** | None | n/a | No iOS development tool by this name exists; see below. |

## ElevenLabs: what's actually current

- The screenshot's "v4" reference turned out to be accurate. **`eleven_v4` launched on 28 Sept 2026 and is GA.** It's ElevenLabs' most expressive model and is Present's default (`ELEVENLABS_MODEL`).
- **Expression controls on v4 (and v3):**
  - Inline audio tags such as `[softly]`, `[warmly]` and `[exhales]`. The script prompt allows them sparingly; they never appear in the transcript, and they're stripped for models that don't support them.
  - SSML `<break>` is *not* supported on v3/v4. Present doesn't need it, because pauses are real silence of exact length.
  - Voice settings on v4 are `stability` and `similarity_boost` only; `speed` and `style` apply to the v2-generation models. Present sends only what each model supports.
- **Request stitching** (`previous_request_ids`) is used on v4 and v2 models for smooth delivery across lines. It's skipped on `eleven_v3`, which doesn't support it.
- Voices come from `GET /v2/voices`. Previews are generated once per voice with meditation text and cached.

## Suno

As of October 2026 Suno has **no official, self-serve developer API**. It is "exploring" one with a small set of partners. Services such as sunoapi.org are unofficial wrappers that break Suno's terms, so Present doesn't use them.

What Present does instead:
1. Generate an instrumental, ambient track in Suno and download it (MP3/WAV).
2. In the app: **Settings → Music → Add a track from Suno…**. The server converts it, levels it and adds it to the rotation (or pick it as your only track).
3. Three original ambient tracks (Linen, Low Tide, Morning Field) are synthesised from scratch by `server/scripts/generate-ambient.py` and released as CC0, so there's never a licensing question about the fallback.

Licensing note: Suno's Free plan is personal, non-commercial use only. Pro and Premier allow commercial use of tracks downloaded within your plan's allowance. For a private app that only you listen to, any plan is fine.

## Lovable

Lovable builds **web apps** (currently TanStack Start / React with Tailwind, plus Supabase/Lovable Cloud). It doesn't produce native iOS code. Present needs native iOS for two of your must-haves:
- **Independent voice and music volume.** iOS Safari ignores `audio.volume`.
- **Reliable locked-screen playback with lock-screen controls.**

So the shipped app is native SwiftUI, and Lovable overlaps only with UI design. It's optional. If you'd like to explore the look in Lovable:

### Prompt to paste into Lovable

> Build a clickable, mobile-only design prototype (iPhone 15 size, 393×852) for a calm personal meditation app called **Present**. It is a design reference for a native SwiftUI app, so no backend, auth or database: use static sample data.
>
> **Feel:** quiet, warm, grounded, unhurried. Lots of space, no clutter, no gamification, no streaks or badges.
> **Colours (light):** background #F5EFE6 (linen), surface #FBF8F3, text #2B2622, secondary text #7A6E63, hairlines #E4DACD, accent clay #B5795A, soft accent #E9D5C3, sage #8C9A80. **Dark mode:** background #1B1916, surface #24211D, text #EEE6DA, secondary #A89C8E, accent #D29B79.
> **Type:** titles in a refined serif (e.g. "New York" or "Newsreader"), body in a clean sans (SF Pro / Inter). Generous line height.
> **Navigation:** a bottom tab bar with exactly three tabs: Today, Library, Settings.
>
> **Today:** small date and time-of-day greeting ("Good morning, Brian"). Today's session as the hero: large serif title (e.g. "The Weight of Here"), "Presence · 10 min", one gentle sentence of summary, and **one prominent circular play button** with a slow breathing glow (4 s in, 6 s out). Below it, a quiet text link "A different session…" opening a bottom sheet with duration pills (5 / 10 / 15 / 20 min), theme pills (Presence, Gratitude, Stress relief, Sleep, Family connection, Letting go of work, Slowing down) and a "Create" button. Also show a "being prepared" state ("Recording the voice…") and a small "Demo" badge variant.
>
> **Player (full screen):** title and theme, a large softly breathing circle, elapsed / remaining time, a thin scrubber, back 15 s / play-pause / forward 15 s, and two labelled sliders: "Voice" and "Music". A close chevron at the top.
>
> **Reflection (after a session):** the reflection question in large serif ("Where in your day today could you stop for three breaths?"), an optional text area ("Write if you'd like — this stays on your iPhone"), and two buttons: "Save" and "Just sit with it".
>
> **Library:** a segmented control (All / Favourites) and a list of past sessions: date, title, theme · duration, a heart, a small downloaded icon. Tapping one opens a detail view with play, favourite, download and that session's journal entries.
>
> **Settings:** grouped sections. Daily session (on/off, "Ready by" time, default length, themes); Voice (list with ▶ preview and a checkmark for the default); Music (tracks with preview and toggles, "Add a track from Suno…"); Reminders; About you (name, people you love, what's on your mind); Privacy (Face ID journal lock, delete journal, delete downloads, delete all server data); Server status.
>
> Use subtle 0.6 s ease-in-out transitions only. Make every screen reachable by clicking.

### Handing it back to Claude Code
1. In Lovable, connect the project to GitHub (**Project settings → GitHub → Connect**). It creates a repo, e.g. `bdm10/present-design`, and keeps it in two-way sync with one branch.
2. Iterate in Lovable until you like it.
3. Start a Claude Code session with both repos and ask: *"Port the visual design from `present-design` (colours, type scale, spacing, components) into the SwiftUI app in `Present-app/ios`. Keep all behaviour and accessibility identifiers."* Claude Code reads the React/Tailwind and translates it into `ios/Present/DesignSystem` and the feature views. Lovable's web code itself isn't shipped.
4. Alternatively, connect the **Lovable MCP server** (research preview on Pro/Business plans) to Claude Code, and Claude Code can drive Lovable directly in a future session.

**If you ever want a web/PWA version instead:** a Lovable app can be added to the Home Screen, and since iOS 16.4 it can get Web Push. But it couldn't do independent voice/music volume or dependable lock-screen playback. Wrapping it with Capacitor for the App Store would still need native audio code. That's why it isn't the main path here.

## "Astra"

I couldn't find any product called Astra that does native iPhone development or offers an integration API. The candidates are:
- **OpenAI GPT-6 "Astra"** (Sept 2026), a general-purpose language model. It can write code, but it isn't an iOS tool, and Claude Code already covers that role here.
- **Google DeepMind Project Astra**, a research assistant programme surfaced through Gemini Live. Not a build tool.
- **DataStax Astra DB**, a hosted database. Present doesn't need one; SQLite on the server is simpler and private.

**Proposed alternative (implemented):** native development uses SwiftUI + XcodeGen. It's compiled and tested on GitHub Actions macOS runners (iOS Simulator unit and UI tests), and you install it on your iPhone with Xcode or TestFlight (see `SETUP.md`). If "Astra" meant something specific to you, tell me and I'll look again.

## Sources
- ElevenLabs models: https://elevenlabs.io/docs/overview/models · v4: https://elevenlabs.io/blog/eleven-v4 · audio tags: https://elevenlabs.io/docs/help-center/product/core-capabilities/text-to-speech/how-do-audio-tags-work-with-eleven-v3-and-v4 · stitching: https://elevenlabs.io/docs/eleven-api/guides/cookbooks/text-to-speech/request-stitching · TTS API: https://elevenlabs.io/docs/api-reference/text-to-speech/convert · pricing: https://elevenlabs.io/pricing/api
- Suno terms: https://suno.com/terms-of-service · developer API status: https://www.musicbusinessworldwide.com/suno-explores-developer-api-seeking-apps-that-unlock-experiences-generative-music-makes-possible-for-the-first-time/
- Claude pricing: https://platform.claude.com/docs/en/about-claude/pricing
- Lovable stack: https://lovable.dev/faq/capabilities/tech-stack/lovable-tech-stack · GitHub: https://docs.lovable.dev/integrations/github · MCP: https://docs.lovable.dev/integrations/lovable-mcp-server
- GPT-6 Astra: https://developers.openai.com/api/docs/models/gpt-6-astra
- Web Push on iOS: https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/
