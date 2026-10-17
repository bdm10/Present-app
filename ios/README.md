# Present — iPhone app

Native SwiftUI app (iOS 17+). It plays each session's two stems (voice and music) in sync with independent volumes, keeps playing when the screen is locked, and supports lock-screen controls, offline downloads, a private on-device journal, and push or local reminders.

```
ios/
  project.yml              XcodeGen spec → Present.xcodeproj
  Present/
    App/                   entry point, AppModel (state + actions), RootView, launch options
    Networking/            APIClient, Codable models (docs/API.md), Keychain
    Audio/                 SessionPlayer (2 × AVAudioPlayer, Now Playing, remote commands), previews
    Storage/               DownloadStore (offline audio), JournalStore (private), LocalSettings
    Services/              notifications, background refresh
    DesignSystem/          palette, typography, breathing circle, pills, buttons
    Features/              Today, Player, Reflection, Library, Settings, Onboarding
    Resources/DemoSession/ bundled demo session (plays with no server)
  PresentTests/            unit tests (models, stores, audio engine)
  PresentUITests/          UI tests (demo flow; full server flow when a server is given)
```

## 1. Generate the Xcode project

You need a Mac with Xcode 16 or later.

```bash
brew install xcodegen
cd ios
xcodegen generate
open Present.xcodeproj
```

Run `xcodegen generate` again whenever files are added or `project.yml` changes. The generated `.xcodeproj` isn't committed.

## 2. Run it on your iPhone with a free Apple ID

1. Plug in your iPhone and trust the Mac when asked. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode**, which needs a restart.
2. In Xcode, select the **Present** target, then **Signing & Capabilities**:
   - Tick **Automatically manage signing**.
   - Under **Team**, choose your Apple ID. Add it via **Xcode → Settings → Accounts** if it isn't there yet.
   - If Xcode says the bundle ID is taken, change **Bundle Identifier** to something unique, such as `com.yourname.present`. You can also change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
3. Choose your iPhone as the run destination and press **Run** (⌘R).
4. The first time, the iPhone asks you to trust the developer: **Settings → General → VPN & Device Management → your Apple ID → Trust**.

Limits of a free Apple ID:
- The app stops opening after **7 days**. Press Run again to re-sign it.
- **Push notifications aren't available.** Present notices this and sets a local reminder at your chosen time instead.
- Background audio, lock-screen controls, offline downloads, Face ID and background refresh all work.

## 3. Connect to your server

On first launch, choose **Connect to your Present server** and enter:
- the server address, such as `https://present-yourname.fly.dev`
- the access token (`APP_TOKEN`) your server prints when it first starts

The token is stored in the iPhone Keychain. To try the app without a server, choose **Explore the demo**. It plays a bundled sample session, clearly labelled **Demo**.

## 4. Enable push notifications (paid Apple Developer Program, $99/year)

1. In `project.yml`, uncomment `CODE_SIGN_ENTITLEMENTS: Present/Present.entitlements`, then run `xcodegen generate`. You can instead add the **Push Notifications** capability in Xcode.
2. In the Apple Developer portal, go to **Certificates, IDs & Profiles → Keys** and create a key with **Apple Push Notifications service (APNs)** enabled. Download the `.p8` file and note the **Key ID** and your **Team ID**.
3. Set the APNs variables on the server (see the server's `.env.example`). Builds run from Xcode use the APNs *sandbox* environment. TestFlight and App Store builds use *production*. The app reports which one it's using when it registers.
4. On the iPhone, open **Settings → Reminders → Let me know when it's ready**. The footer confirms when the server will push.

## 5. TestFlight (paid account)

1. In App Store Connect, create the app: **My Apps → + → New App**, using the same bundle ID.
2. In Xcode, choose **Any iOS Device (arm64)**, then **Product → Archive**.
3. In the Organizer, choose **Distribute App → App Store Connect → Upload**.
4. After processing, which takes about 10–30 minutes, add yourself as an internal tester under **TestFlight**. Install the **TestFlight** app on your iPhone and accept the invite.
5. TestFlight builds expire after 90 days. Upload a new build to keep going.

Before uploading, set `CURRENT_PROJECT_VERSION` (the build number) to a higher value each time, in `project.yml` or the target's settings.

## 6. Tests

```bash
cd ios && xcodegen generate
xcodebuild test -project Present.xcodeproj -scheme Present \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

- **Unit tests** cover JSON models, offline download storage (paths, file protection, backup exclusion), journal persistence, and the audio engine: both stems load and have the same length, seeking keeps them aligned, volumes are independent, play and pause work, the `.playback` category is set, and background audio is declared in Info.plist.
- **UI tests:**
  - The demo flow (play, elapsed time advances, pause, mini player, library) always runs.
  - The full server flow (create → generate → play → reflection → journal → favourite) runs when you pass a server:
    ```bash
    TEST_RUNNER_PRESENT_TEST_SERVER_URL=http://localhost:8787 \
    TEST_RUNNER_PRESENT_TEST_TOKEN=<token> xcodebuild test …
    ```
    Use `localhost` rather than `127.0.0.1`, because App Transport Security allows only local networking over plain HTTP.

Some audio checks need an audio output device. On headless CI simulators that have none, those tests are **skipped with a message** rather than passed silently.

### Launch arguments (development and tests)

| Argument | Effect |
|---|---|
| `-PresentServerURL <url> -PresentToken <t>` | Connect to a server and skip onboarding |
| `-PresentDemoOnly YES` | Open straight into the bundled demo |
| `-PresentResetState YES` | Wipe local state: token, downloads, journal, preferences |
| `-PresentFastFinish YES` | Sessions end after 3 s, so the reflection can be tested |
| `-PresentUITest YES` | Turn off continuous animations |

## Privacy

- **Journal entries never leave the iPhone.** They're stored in a file with `NSFileProtectionComplete` (encrypted while the phone is locked), with an optional Face ID lock. **Settings → Privacy & data** deletes entries one at a time or all at once.
- **Downloaded audio** uses `completeUntilFirstUserAuthentication` protection so it can play while the phone is locked. It's excluded from iCloud backup.
- The server token is stored in the Keychain (`AfterFirstUnlockThisDeviceOnly`).
- **Delete all my data on the server** wipes sessions, scripts, audio, uploads, your profile and device registrations from the server.
