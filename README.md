# One-command Flutter releases

Build a signed Android App Bundle and an iOS release build, then upload both
to the stores, with one command. Includes a `--dry-run` mode that needs **no paid
Apple or Google accounts**: the builds are real, and the store uploads are printed and simulated.

## Try it (free, ~1 minute on a warm cache)

```bash
cp .env.example .env
./scripts/create_dummy_keystore.sh     # throwaway local Android keystore
./scripts/build_prod.sh --dry-run      # real .aab + unsigned iOS build, simulated uploads
```

Artifacts land in `dist/`. Requirements: Flutter, Java 17, and Xcode (macOS) for iOS.

## Scripts

| Script | What it does |
|--------|--------------|
| `scripts/build_prod.sh` | Version bump → release safety check → signed `.aab` → iOS `.ipa` → Google Play internal track + TestFlight → changelog → webhook ping |
| `scripts/build_dev.sh` | Version bump → `.apk` + iOS build → auto-install on a connected Android phone → Firebase App Distribution → team message |
| `scripts/create_dummy_keystore.sh` | Generates a demo keystore from the values in `.env` |

Common flags: `--dry-run`, `--skip-ios`, `--skip-android`, `--skip-upload` (prod), `--no-clean`,
and an optional explicit version: `./scripts/build_prod.sh 2.0.0 42`. Run with `--help` for details.

## How it stays safe
- **Secrets live only in `.env`** (gitignored). Gradle reads signing values from environment variables.
- **No config file edits.** Dev and prod API URLs come from `config/dev.json` and `config/prod.json` via `--dart-define-from-file`.
- **Release safety check.** Any line containing `DEV_ONLY` in `lib/` blocks a production build.
- **Signature check.** The script reads the certificate back out of the `.aab` and fails if it isn't signed.
- **Non-releasing uploads.** Builds go to the internal track and TestFlight, and a human still presses release.

## From dry run to real store uploads

The dry run is free and needs no accounts. Real uploads need **paid developer accounts and a
one-time setup** per store. Do this once, then run the same command **without** `--dry-run`.

> The demo uses `com.example.builddemo`. Both stores need your own unique ID, and
> Google Play rejects any package name that starts with `com.example`.

### Google Play
1. **Play Console account** ($25, one-time): https://play.google.com/console
2. **Your own package name:** change `applicationId` and `namespace` in `android/app/build.gradle.kts`,
   and set `ANDROID_PACKAGE_NAME` in `.env` to match.
3. **Your own upload keystore:** set strong passwords in `.env`, point `ANDROID_KEYSTORE_PATH` at a new
   file, and run `./scripts/create_dummy_keystore.sh` (it creates a real keystore from your `.env` values).
   **Back it up and never commit it.**
4. **Create the app in Play Console and upload the first `.aab` by hand.**
   Google requires the first upload of a new app to be done in the web console.
   Build it with `./scripts/build_prod.sh --skip-ios --skip-upload`.
5. **Service account for uploads:** create one in Google Cloud, give it access in
   Play Console → Users and permissions, download its JSON key, and set `PLAY_JSON_KEY_PATH` in `.env`.
   Guide: https://docs.fastlane.tools/actions/supply/#setup
6. **Install fastlane:** `brew install fastlane`

### Apple App Store (TestFlight)
1. **Apple Developer Program** ($99/year): https://developer.apple.com/programs/
2. **Your own bundle ID:** change it in Xcode (Runner target → General), register it in your developer
   account, create the app in App Store Connect, and set `IOS_BUNDLE_ID` in `.env`.
3. **Signing:** open `ios/Runner.xcworkspace` in Xcode → Runner → Signing & Capabilities →
   tick "Automatically manage signing" and pick your Team.
4. **Export options:** create `ios/ExportOptions.plist`, then set `IOS_EXPORT_OPTIONS_PLIST=ios/ExportOptions.plist` in `.env`:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>method</key><string>app-store-connect</string>
     <key>teamID</key><string>YOUR_TEAM_ID</string>
   </dict>
   </plist>
   ```
5. **Upload key:** App Store Connect → Users and Access → Integrations → App Store Connect API →
   create a key (App Manager role). Save the downloaded `AuthKey_<KEY_ID>.p8` in
   `~/.appstoreconnect/private_keys/`, then set `ASC_KEY_ID` and `ASC_ISSUER_ID` in `.env`.

### Run it for real
```bash
./scripts/build_prod.sh
```
Builds land on the Play **internal testing** track and in **TestFlight**. Nothing is published to
users automatically: you still add release notes and press release yourself.

You can set up one store at a time: `--skip-ios` or `--skip-android` builds and uploads only the other.
