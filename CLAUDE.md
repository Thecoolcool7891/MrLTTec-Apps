# MrLTTec-Apps — how this repo works (read this first)

This repo holds MrLTTec's iPhone apps and publishes them as a sideload source.
**You do NOT need a Mac.** GitHub Actions builds every IPA on a macOS runner. Your job is to
edit Swift code here and `git push` — the build, release and source update happen automatically.

## The owner

- Phone: **iPhone 17 Pro on iOS 27.2**. Build every app iPhone-only, portrait, SwiftUI, deployment target `26.0`.
- Installs apps with **Flare Store** (a signer that reads AltStore-style sources). Updating = Flare Store → Library → the app → Update.
- Source link to give people (fastest): `https://github.com/Thecoolcool7891/MrLTTec-Apps/releases/download/source/source.json`
  (`https://raw.githubusercontent.com/Thecoolcool7891/MrLTTec-Apps/main/source.json` also works but GitHub caches it up to ~5 min).
- Prefers plain, short explanations. When asked to hold changes ("don't push until I say go"), work on a test branch (see below) and only merge to `main` after they say **go**.

## Layout

```
apps/<Name>/            one folder per app
  project.yml           XcodeGen spec (generates the .xcodeproj on the runner — never commit .xcodeproj)
  app.json              name, scheme, bundleIdentifier, description, tintColor, minOSVersion, baseVersion
  icon.png              1024×1024 icon shown in the source
  Sources/              Swift code + Assets.xcassets/AppIcon.appiconset/icon.png (same 1024 icon)
apps/SmartHome/Broadcast/   screen-broadcast app extension (MrLTTec Mirror)
shared/Updater.swift    in-app "update available" banner + sheet (included by SmartHome via project.yml)
scripts/build_app.sh    builds one app → unsigned IPA → GitHub Release
scripts/update_source.py adds the new version to source.json
.github/workflows/publish.yml     on push to main: build changed apps, release, update source.json, re-upload it to the "source" release
.github/workflows/test-build.yml  on push to any other branch: compile only, publish nothing
source.json             the AltStore source (written by the bot — don't hand-edit unless fixing it)
```

Current apps: **BuzzLab** (haptics playground, `com.mrlttec.buzzlab`), **SmartHome** = "MrLTTec Home" (`com.mrlttec.smarthome`)
and **HomeControl** = "MrLTTec Control" (`com.mrlttec.homecontrol`, the owner's own room over Tailscale).

## Shipping a change

1. Edit code under `apps/<Name>/…` (or `shared/`, which rebuilds every app).
2. `git add -A && git commit -m "..."` then `git push` to `main`.
3. The publish workflow builds **only apps whose folder changed** (changes in `scripts/` or `shared/` rebuild all).
   Version = `baseVersion` from app.json + `.` + the workflow run number (e.g. 2.0.20) — no manual bumping.
   Bump `baseVersion` (e.g. "2.0" → "3.0") only for big redesigns.
4. A build takes ~2–10 min. Only after it finishes does the new version appear in source.json; then allow up to a few minutes of GitHub caching.
5. Before telling the owner it's ready, **verify** it's live:
   ```bash
   curl -sL https://github.com/Thecoolcool7891/MrLTTec-Apps/releases/download/source/source.json | python -c "import json,sys;[print(a['name'],a['version']) for a in json.load(sys.stdin)['apps']]"
   ```

### Test branch (compile without publishing)
```bash
git checkout -b my-feature && git push -u origin my-feature   # test-build.yml compiles it, nothing is released
# when the owner says go:
git checkout main && git pull && git merge my-feature && git push
```

### Checking a build / reading compile errors
- Status (anonymous API, **limit 60 requests/hour per IP — poll every 60–90 s, not faster**):
  `https://api.github.com/repos/Thecoolcool7891/MrLTTec-Apps/actions/runs?branch=main&per_page=1`
- Job logs need a signed-in GitHub session. In a browser that's signed in, open the run page, or fetch
  `/Thecoolcool7891/MrLTTec-Apps/commit/<full-sha>/checks/<job-id>/logs` from a github.com tab and grep for `error:`.
  Job id: `https://api.github.com/repos/Thecoolcool7891/MrLTTec-Apps/actions/runs/<run-id>/jobs`.

### Pushing from Windows
Git Credential Manager holds the GitHub login. If a push fails with "could not read Username", run `git push` once in an
interactive terminal so the browser sign-in can pop up; after that pushes work non-interactively. `gh` CLI is not installed.

## News (shows in the store's News tab)

Edit `news/news.json` (newest can go anywhere; it's sorted by date) and put pictures in `news/images/` (about 1200×600 PNG).
Fields are documented at the top of `news/apply_news.py`: `identifier` (unique, never reused), `title`, `caption`,
`date` (ISO with time, e.g. `2026-11-15T19:30:00-05:00`), optional `image` (file name in news/images), `appID`, `url`,
`tintColor`, `notify`. Push to main: the publish workflow copies it into `source.json` (no app rebuild) and re-uploads
the uncached source. Don't hand-edit `news` inside source.json — it gets overwritten from news.json.

## Adding a new app

1. Copy `apps/BuzzLab` as a template → `apps/<NewName>/`. Update `project.yml` (name, target, scheme, bundle id
   `com.mrlttec.<lowercase>`), `app.json` (scheme must equal the target name), `icon.png` + the AppIcon asset.
2. Keep in project.yml: `SWIFT_VERSION: "5.0"`, deployment target `26.0`, `TARGETED_DEVICE_FAMILY: "1"`,
   `CODE_SIGNING_ALLOWED: "NO"`, `scheme: {}`, Info.plist keys `CFBundleShortVersionString: $(MARKETING_VERSION)` and
   `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`.
3. Optionally include `../../shared` in `sources` and add the Updater (see SmartHome `App.swift`: `Updater(bundleId: "...")`).
4. Push. The workflow builds it and adds it to source.json automatically.

## Swift gotchas we already hit (you can't compile locally — avoid these)

- Language mode is Swift 5. Regex literals must use `#/ ... /#` (bare `/.../` doesn't compile in this mode).
- `try`/`await` can't sit on the right side of `?:` — use if/else.
- Don't name a type `Scene` (clashes with SwiftUI.Scene) or other SwiftUI names.
- No tuple key paths in `ForEach(..., id: \.0)` — use small structs or `[[String]]` with `id: \.self`.
- `if let (a, b) = ...` isn't allowed — bind the tuple, then use `.0/.1`.
- `Slider` editing callback: write `onEditingChanged:` explicitly.
- Big-number / byte code: Swift traps on overflow and out-of-range indexes — test math in Python first when possible.
- Keep everything iOS 26 SDK compatible; Liquid Glass APIs (`Tab`, `.tabBarMinimizeBehavior`) are fine.

## MrLTTec Home (apps/SmartHome) — what it is

A **take-anywhere tool for other people's Wi-Fi** (show off, help people, test networks). **Local network only — no
cloud logins or account features** (e.g. Xbox stays "turn on" only). Native SwiftUI, brown/gold theme
(`Theme.gold`, `Theme.brown`), tabs: Devices, Discover, Tools, Settings (tab bar minimizes on scroll).

Key files in `Sources/`: `LowNet.swift` (BSD sockets: TCP/UDP/ICMP sweeps, blocking stream), `Http.swift`
(URLSession, trusts self-signed certs on private IPs, tiny XML helpers, `Store` key/value), `Store.swift` (device model +
saved devices), `Discovery.swift` (network scan, host list, net tools), `Devices.swift` (Wemo, WLED, Roku, WiZ, Xbox, WoL),
`Samsung.swift`, `Sonos.swift`, `FireTV.swift` (PIN API), `Adb.swift` (adb wire protocol + RSA key, mirroring helpers),
`AppleTV.swift` + `AppleTVCrypto.swift` (Companion protocol: SRP-6a 3072, OPACK, TLV8, ChaCha20), `AirPlay2.swift`
(HAP pairing over HTTP:7000, photos/videos), `Cast.swift` (Google Cast, DLNA, DIAL YouTube, AirPlay 1),
`MediaServer.swift` (phone file server for casting), `MirrorView.swift` (screen-mirror UI, quality, viewer count),
`HealthView.swift`, `Report.swift` (error log + Report a problem), views per device.
`Broadcast/` = ReplayKit extension: H.264 → MPEG-TS (`/screen.ts` for DLNA), HLS (`/live.m3u8` for Chromecast/AirPlay),
MJPEG + web page (`/` and `/mjpeg` for browsers) on port 8799; `/status` JSON, `/config?quality=&lowlag=`.

The original PC version (PowerShell server + web page) lives in
`C:\Users\Landon\Downloads\Websites\MrLTTec Smart Home Tool` on the laptop — useful as a protocol reference.

## Ideas the owner liked but hasn't asked to build yet
Sound in mirroring; Personal Hotspot flow for browser mirroring; passcode for the browser page; "visit mode" report;
share a device by QR; instant remote settings file (announcements/feature switches); Live Activity while broadcasting.
Not wanted in this app: Control Center buttons, cloud/account features.
