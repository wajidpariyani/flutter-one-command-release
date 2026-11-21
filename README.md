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

## Going real
Fill in `PLAY_JSON_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `IOS_EXPORT_OPTIONS_PLIST` in `.env`,
install fastlane, and drop `--dry-run`.
