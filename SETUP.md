# Present: setup guide

Three parts: **(1)** run the backend, **(2)** install the app on your iPhone, **(3)** connect them. Everything works in demo mode first, so you can try it before adding any API keys.

What you need:
- A Mac with **Xcode 16 or newer** (free from the App Store) and Homebrew. You can install without a Mac via TestFlight (§2C), but that needs a paid Apple Developer account and some one-time setup.
- An iPhone on **iOS 17+**.
- Optional, for real sessions: an **Anthropic API key** (console.anthropic.com) and an **ElevenLabs API key** (elevenlabs.io → Developers → API keys).

---

## 1. Run the backend

### A. Try it on your Mac (5 minutes, demo mode)
```bash
brew install node@22 ffmpeg
cd server
cp .env.example .env              # leave the keys blank for demo mode
npm install
npm run dev                       # http://localhost:8787
```
The first start prints a generated access token and saves it in `server/data/app-token.txt`. Your iPhone can reach this Mac at `http://<your-mac's-name>.local:8787` on the same Wi-Fi. That's fine for testing, but the daily schedule only runs while the Mac is awake.

### B. Deploy it so it runs 24/7 (recommended: Fly.io, ≈ $4/month)
The scheduler needs an always-on server so your morning session is generated while the app is closed.
```bash
brew install flyctl && fly auth signup        # or: fly auth login
cd server
fly launch --no-deploy --copy-config --name present-<yourname>
fly volumes create present_data --size 3 --region <same region as the app>
fly secrets set APP_TOKEN="$(openssl rand -base64 32)"
fly secrets set ANTHROPIC_API_KEY=sk-ant-...  ELEVENLABS_API_KEY=...     # optional; omit for demo mode
fly secrets set MONTHLY_SPEND_LIMIT_USD=15
fly deploy
fly secrets list    # APP_TOKEN's value isn't shown again: keep a copy of it now (e.g. in your password manager)
```
Your server URL is `https://present-<yourname>.fly.dev`. Check it with:
```bash
curl https://present-<yourname>.fly.dev/health
curl -H "Authorization: Bearer <APP_TOKEN>" https://present-<yourname>.fly.dev/api/status
```
`/api/status` says honestly whether scripts, voice and push are **live** or **demo**.

The `server/Dockerfile` also runs on Railway, Render or any Docker host. Mount a persistent disk at `/data` and keep exactly one instance running.

All settings are documented in [`server/.env.example`](server/.env.example).

---

## 2. Install the app on your iPhone

First, once on your Mac:
```bash
brew install xcodegen
cd ios && xcodegen generate && open Present.xcodeproj
```

### A. Free Apple ID (no cost; re-install every 7 days)
1. In Xcode, select the **Present** target → **Signing & Capabilities** → tick *Automatically manage signing* and choose your **Personal Team** (add your Apple ID in Xcode → Settings → Accounts if needed).
2. If Xcode says the bundle ID is taken, change `com.present.meditation` to something unique, e.g. `com.<yourname>.present`.
3. Plug in your iPhone. On the phone, enable **Settings → Privacy & Security → Developer Mode** and restart.
4. Choose your iPhone as the run destination and press **Run (⌘R)**.
5. On the phone, trust the developer: **Settings → General → VPN & Device Management → your Apple ID → Trust**.

Limits of a free account: the app stops opening after **7 days** (just press Run again), and **push notifications aren't available**. Present then uses a local daily reminder at your chosen time instead. Background playback, the lock screen and offline downloads all work.

### B. Paid Apple Developer account ($99/year): push and no weekly re-install
1. Join at developer.apple.com/programs and select your team in Xcode → Signing.
2. **Enable push:** in `ios/project.yml`, uncomment `CODE_SIGN_ENTITLEMENTS: Present/Present.entitlements`, then run `xcodegen generate` again.
3. Create an APNs key: developer.apple.com → Certificates, IDs & Profiles → **Keys → +** → tick *Apple Push Notifications service (APNs)* → download the `.p8` (you can only download it once). Note the **Key ID** and your **Team ID**.
4. Give the server the key:
   ```bash
   fly secrets set APNS_KEY_ID=ABC123DEFG APNS_TEAM_ID=XYZ987 APNS_BUNDLE_ID=<your bundle id> \
                   APNS_KEY_P8="$(cat AuthKey_ABC123DEFG.p8)"
   ```
5. Run the app on your phone and allow notifications. `/api/status` will show push as configured.

### C. TestFlight (paid account; installs that last 90 days, no cable)
1. Create the app record: **App Store Connect → My Apps → + → New App**, with your bundle ID and the name "Present" (or "Present – Meditation" if the name is taken).
2. In Xcode choose **Any iOS Device (arm64)** → **Product → Archive** → **Distribute App → TestFlight & App Store** → Upload.
3. In App Store Connect → TestFlight, add yourself under **Internal Testing**. Internal testers don't need Beta App Review.
4. Install **TestFlight** on your iPhone and accept the invite.
5. Builds expire after 90 days. Upload a new archive to refresh.

Release builds register for push with the **production** APNs environment automatically. Debug builds from Xcode use **sandbox**.

---

## 3. Connect the app

1. Open Present. Choose **Connect to your Present server**, enter the server URL and your `APP_TOKEN`. The token is stored in the iPhone Keychain.
   - Or choose **Explore the demo** to hear the bundled 5-minute sample with no server at all.
2. The app sends your iPhone's time zone to the server.
3. Settings:
   - **Daily session:** set a **Ready by** time. Generation starts 30 minutes earlier, and you're notified once it's ready.
   - **Voice:** tap ▶ to preview each voice, then tick your default.
   - **Music:** preview the built-in tracks, or **Add a track from Suno…** to upload your own.
   - **About you:** optional. A name, the people you love, and what's on your mind help personalise scripts. This is stored on your server and sent to Claude when writing scripts.
4. Tap the play button on **Today**. Lock the phone. Playback continues and the lock screen shows the controls.

### Going live (leaving demo mode)
Add `ANTHROPIC_API_KEY` **and** `ELEVENLABS_API_KEY` on the server and redeploy (`fly secrets set …` restarts it). The two work together: the demo voice can only read the pre-written demo scripts. `/api/status` and Settings → Server will show **Live**.

Suggested first steps once live:
- Shortlist calm voices with `ELEVENLABS_VOICE_IDS=id1,id2,id3`. Voice IDs are in your ElevenLabs Voice Library; "My Voices" includes any you've added.
- Create one 5-minute session from Today → *A different session…* and listen through before relying on the daily schedule.

---

## Privacy and deletion
- **API keys** live only on the server. The app holds just the server URL and the access token (in the Keychain).
- **Journal entries never leave your iPhone.** They're stored with iOS Complete file protection (unreadable while the phone is locked), and you can lock them with Face ID. Delete them in Settings → Privacy.
- **Server data:** Settings → Privacy → *Delete all server data* removes sessions, audio, scripts, uploads, your profile, device tokens and caches. A record of past spending amounts (dates and dollars only) is kept, so the spending limit can't be bypassed.
- Downloads can be removed per session, or all at once.
- Old audio of non-favourite sessions is removed from the server after `AUDIO_RETENTION_DAYS` (default 60).

## Troubleshooting
| Symptom | Fix |
|---|---|
| "Access token was not accepted" | Re-enter `APP_TOKEN` exactly (Settings → Server → Disconnect, then connect again). |
| Session failed: "spending limit" | Raise `MONTHLY_SPEND_LIMIT_USD` or wait for next month. Check Settings → Server for this month's spend. |
| No morning notification | Free Apple ID → local reminder only (check iOS Settings → Notifications → Present). Paid → check `APNS_*` and `/api/status`. |
| Can't reach a server on your Mac from the phone | Use `http://<mac-name>.local:8787` and allow Local Network access when asked. Plain HTTP is only allowed for local addresses. |
| Daily session didn't appear | `fly logs`. The scheduler only starts after the app has saved your settings once (so it knows your time zone). |
