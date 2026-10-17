# Try Present on your iPhone: the built-in demo

This installs the app straight from Xcode with a **free Apple ID**. The demo session (5 minutes, "The Weight of Here") is built into the app, so you need **no server, no API keys and no paid accounts**. It plays fully offline.

Allow about 45–60 minutes the first time. Most of that is downloading Xcode.

---

## Step 0: check compatibility (2 minutes)

| What | Where to check | You need |
|---|---|---|
| iPhone iOS version | iPhone: **Settings → General → About → iOS Version** | **iOS 17 or later** (iPhone XS / XR or newer) |
| Mac macOS version | Mac: ** menu → About This Mac** | Depends on your iPhone's iOS version (next row) |
| Which Xcode | Apple's table: https://developer.apple.com/xcode/system-requirements/ | **iPhone on iOS 27.x → Xcode 27.1**, which needs **macOS Tahoe 26.6 or later**. **iPhone on iOS 26.x → Xcode 26.6** also works, and runs on **macOS Tahoe 26.2 or later**. |
| Free disk space on the Mac | ** → System Settings → General → Storage** | About **40 GB** (Xcode plus the iOS platform download) |
| Cable | | A USB-C or Lightning cable that carries data |

If your Mac can't run the macOS version needed for your iPhone's iOS, Xcode can't install apps on that iPhone. Tell me what you have and I'll suggest the best route.

## Step 1: install Xcode (30–45 minutes, mostly waiting)
1. Open the **App Store** on the Mac, search for **Xcode**, and click **Get**. It's free and about 3 GB to download.
2. Open Xcode once. Accept the licence. When asked which platforms to install, tick **iOS**. That's another download of several GB.

## Step 2: add your Apple ID to Xcode (2 minutes)
1. Xcode → **Settings…** (⌘,) → **Accounts** → **+** → **Apple Account** → sign in with your normal Apple ID.
2. A "(Personal Team)" appears under your name. That's the free signing team.

## Step 3: get the code (2 minutes)
- **Easiest:** on GitHub, open the repository, switch to branch **`claude/present-app-build`** (or `main` once the pull request is merged), then click **Code → Download ZIP**. Unzip it.
- Or in Terminal: `git clone -b claude/present-app-build https://github.com/bdm10/Present-app.git`

## Step 4: open the project and set signing (3 minutes)
1. Double-click **`ios/Present.xcodeproj`**.
2. In the left sidebar, click the blue **Present** project icon. Under **Targets**, select **Present**, then open the **Signing & Capabilities** tab.
3. Tick **Automatically manage signing**. Set **Team** to *Your Name (Personal Team)*.
4. Change **Bundle Identifier** from `com.present.meditation` to something unique to you, e.g. `com.brianmcnerney.present`. Free accounts can't use an ID someone else has registered.
5. The red errors should clear within a few seconds. If a **Push Notifications** error appears, you can ignore it: push is switched off by default for free accounts.

## Step 5: prepare your iPhone (5 minutes, one time only)
1. Connect the iPhone to the Mac with the cable. Unlock it and tap **Trust** when asked, then enter your passcode.
2. In Xcode's top bar, click the device selector next to **Present** and choose your iPhone. Xcode may show "Preparing iPhone…" for a few minutes the first time.
3. On the iPhone: **Settings → Privacy & Security → Developer Mode → On**. The phone restarts; after restarting, tap **Turn On** and enter your passcode. The Developer Mode switch only appears after the iPhone has been connected to Xcode once.

## Step 6: install and run (2–5 minutes)
1. In Xcode press **▶ Run** (⌘R).
2. The first time, iOS blocks the app with "Untrusted Developer". On the iPhone: **Settings → General → VPN & Device Management → (your Apple ID) → Trust**. Then press Run again, or tap the Present icon.
3. In Present, choose **Explore the demo**.

---

## What to test

**Design**
- [ ] Today, Library and Settings feel calm and uncluttered; the text is easy to read. Also try dark mode: Settings → Display & Brightness.
- [ ] Larger text: Settings → Accessibility → Display & Text Size → Larger Text.

**Audio**
- [ ] Tap play. Music fades in for a few seconds before the voice begins.
- [ ] Voice and music sliders change each one independently, live.
- [ ] Music dips gently under the voice and rises in the pauses.
- [ ] Back 15 s / forward 15 s, and dragging the scrubber.
- [ ] Sound plays even with the **silent switch** on (expected for a meditation app).

**Locked-screen playback** (couldn't be tested in the simulator)
- [ ] Start a session and press the **side button** to lock. Audio keeps playing.
- [ ] On the lock screen: title "The Weight of Here", play/pause, ±15 s and the scrubber all work.
- [ ] Control Centre shows the same controls.
- [ ] Unplug or disconnect headphones mid-session. It pauses rather than switching to the speaker.
- [ ] Ask someone to phone you mid-session. It pauses, and resumes after the call if iOS allows.

**Offline**
- [ ] Turn on **Airplane Mode** and play. The demo works fully offline.

**After the session**
- [ ] At the end (after 5 minutes, or drag the scrubber near the end), the reflection question appears. Write a note and tap **Save**. The Save button stays above the keyboard.
- [ ] Library → open the session → your journal entry is there. Favourite it, and it shows under **Favourites**.

Any issues: tell me what you saw (a screenshot helps) and I'll fix it.

---

## Good to know
- **Free Apple ID limits:** the app stops opening after **7 days**. Plug in and press Run again; your journal and settings are kept. Up to 3 sideloaded apps at a time.
- **No push notifications** on a free account. The daily reminder becomes a local notification once you connect a server.
- **Next steps (after you've tested):** connect a server for daily sessions, then add ElevenLabs and Claude keys and online hosting. See [`SETUP.md`](../SETUP.md).
