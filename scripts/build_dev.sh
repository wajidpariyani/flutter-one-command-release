#!/bin/bash
# =============================================================================
# DEV build: Flutter -> APK + iOS build -> devices + Firebase App Distribution
# =============================================================================
# Usage:
#   ./scripts/build_dev.sh                 # bump patch+1, build+1
#   ./scripts/build_dev.sh 2.7.2 173       # explicit version and build number
#   ./scripts/build_dev.sh --dry-run       # real local builds, SIMULATED distribution
#   ./scripts/build_dev.sh --skip-ios      # Android only
#   ./scripts/build_dev.sh --skip-android  # iOS only
#   ./scripts/build_dev.sh --no-clean      # skip `flutter clean` (faster)
#
# What it does:
#   - Builds a release APK against config/dev.json (dev API URLs)
#   - Builds iOS (signed ad-hoc .ipa if IOS_DEV_EXPORT_OPTIONS_PLIST is set,
#     otherwise an unsigned build)
#   - Installs the APK on a connected Android phone (adb) automatically
#   - Uploads to Firebase App Distribution (free) if the app ids are set
#   - Prints a ready-to-paste team message and posts it to a webhook if set
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"
SCRIPT_START=$(date +%s)

NEW_VERSION=""; NEW_BUILD=""
SKIP_IOS=false; SKIP_ANDROID=false; DRY_RUN=false; CLEAN=true

for arg in "$@"; do
    case $arg in
        --dry-run)      DRY_RUN=true ;;
        --skip-ios)     SKIP_IOS=true ;;
        --skip-android) SKIP_ANDROID=true ;;
        --no-clean)     CLEAN=false ;;
        -h|--help)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)             echo "Unknown option: '$arg' (see --help)" >&2; exit 1 ;;
        *)  if [ -z "$NEW_VERSION" ]; then NEW_VERSION="$arg"
            elif [ -z "$NEW_BUILD" ]; then NEW_BUILD="$arg"; fi ;;
    esac
done

LOG_TAG="DEV"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
ACCENT="$BLUE"
trap on_error EXIT

if [ "$DRY_RUN" = true ]; then
    banner "DEV BUILD | DRY RUN (distribution simulated)"
else
    banner "DEV BUILD"
fi

# =============================================================================
step "Preflight checks"
# =============================================================================
load_env
APP_NAME="${APP_NAME:-app}"
ARTIFACT_DIR="$APP_DIR/${ARTIFACT_DIR:-dist}"
mkdir -p "$ARTIFACT_DIR"

require_tools flutter git
[ "$SKIP_ANDROID" = true ] || require_tools java
[ "$SKIP_IOS" = true ] || require_tools xcodebuild
[ -f config/dev.json ] || die "config/dev.json not found"
ok "Dev config: config/dev.json ($(grep -o '"API_BASE_URL": *"[^"]*"' config/dev.json | sed 's/.*": *"//; s/"$//'))"
check_branch "${DEV_BRANCH:-}"

# =============================================================================
step "Version management"
# =============================================================================
compute_version
write_version

# =============================================================================
step "Clean & dependencies"
# =============================================================================
prepare_deps "$CLEAN"

BUILD_ARGS=(--release
    --build-name="$NEW_VERSION" --build-number="$NEW_BUILD"
    --dart-define-from-file=config/dev.json
    --dart-define=BUILD_VERSION="$NEW_VERSION+$NEW_BUILD")
BASENAME="${APP_NAME}-dev-v${NEW_VERSION}+${NEW_BUILD}"
APK_DEST=""; IPA_DEST=""; IPA_SIGNED=false

# =============================================================================
if [ "$SKIP_ANDROID" = false ]; then
step "Android APK"
# =============================================================================
    flutter build apk "${BUILD_ARGS[@]}"
    APK_DEST="$ARTIFACT_DIR/$BASENAME.apk"
    cp build/app/outputs/flutter-apk/app-release.apk "$APK_DEST"
    ok "Saved: ${APK_DEST#$APP_DIR/} ($(human_size "$APK_DEST"))"
fi

# =============================================================================
if [ "$SKIP_IOS" = false ]; then
step "iOS build"
# =============================================================================
    if [ "$DRY_RUN" = false ] && [ -n "${IOS_DEV_EXPORT_OPTIONS_PLIST:-}" ]; then
        flutter build ipa "${BUILD_ARGS[@]}" --export-options-plist="$IOS_DEV_EXPORT_OPTIONS_PLIST"
        IPA_DEST="$ARTIFACT_DIR/$BASENAME.ipa"
        cp "$(find build/ios/ipa -name '*.ipa' | head -1)" "$IPA_DEST"
        IPA_SIGNED=true
    else
        flutter build ios "${BUILD_ARGS[@]}" --no-codesign
        IPA_DEST="$ARTIFACT_DIR/$BASENAME-unsigned.ipa"
        rm -f "$IPA_DEST"
        package_unsigned_ipa "$APP_DIR/build/ios/iphoneos/Runner.app" "$IPA_DEST"
    fi
    ok "Saved: ${IPA_DEST#$APP_DIR/} ($(human_size "$IPA_DEST"))$([ "$IPA_SIGNED" = true ] || echo ' — unsigned')"
fi

# =============================================================================
step "Install on connected devices"
# =============================================================================
if [ -n "$APK_DEST" ] && command -v adb >/dev/null 2>&1; then
    DEVICE=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')
    if [ -n "$DEVICE" ]; then
        log "Android device found: $DEVICE — installing..."
        if adb -s "$DEVICE" install -r "$APK_DEST"; then ok "APK installed on $DEVICE"; else warn "APK install failed on $DEVICE"; fi
    else
        log "No Android device connected — skipping install"
    fi
else
    log "No APK or adb not found — skipping Android install"
fi
if [ "$IPA_SIGNED" = true ] && command -v ios-deploy >/dev/null 2>&1; then
    ios-deploy --bundle "$IPA_DEST" && ok "IPA installed" || warn "IPA install failed (unlock the device / trust the profile)"
else
    log "No signed .ipa or ios-deploy not found — skipping iOS install"
fi

# =============================================================================
step "Firebase App Distribution"
# =============================================================================
ANDROID_LINK="(not distributed)"; IOS_LINK="(not distributed)"
RELEASE_NOTES="Dev build ${NEW_VERSION} (${NEW_BUILD})"

distribute() {
    # $1 = file, $2 = Firebase app id, $3 = label. Prints the tester link.
    local file="$1" app_id="$2" label="$3" out link
    out=$(firebase appdistribution:distribute "$file" --app "$app_id" --release-notes "$RELEASE_NOTES" 2>&1) || true
    link=$(echo "$out" | grep -o 'https://appdistribution[^ ]*' | head -1 || true)
    if [ -n "$link" ]; then
        ok "$label distributed" >&2; echo "$link"
    else
        warn "$label upload failed:" >&2; echo "$out" | tail -5 >&2
        echo "(upload failed — see log)"
    fi
}

if [ -n "$APK_DEST" ]; then
    if [ "$DRY_RUN" = true ]; then
        dry "Would run: firebase appdistribution:distribute ${APK_DEST#$APP_DIR/} --app $(mask "${FIREBASE_ANDROID_APP_ID:-}")"
        simulate_upload "Firebase App Distribution" "$APK_DEST" "Android testers group" \
            "Authenticating with Firebase CLI..." "Authenticated"
        ANDROID_LINK="(dry run)"
    elif [ -n "${FIREBASE_ANDROID_APP_ID:-}" ] && command -v firebase >/dev/null 2>&1; then
        ANDROID_LINK=$(distribute "$APK_DEST" "$FIREBASE_ANDROID_APP_ID" "Android APK")
    else
        warn "FIREBASE_ANDROID_APP_ID or firebase CLI missing — skipping Android distribution"
    fi
fi
if [ -n "$IPA_DEST" ]; then
    if [ "$DRY_RUN" = true ]; then
        dry "Would run: firebase appdistribution:distribute ${IPA_DEST#$APP_DIR/} --app $(mask "${FIREBASE_IOS_APP_ID:-}")"
        dry "Skipped: Firebase needs an ad-hoc signed .ipa for iOS testers"
        IOS_LINK="(dry run)"
    elif [ "$IPA_SIGNED" = true ] && [ -n "${FIREBASE_IOS_APP_ID:-}" ] && command -v firebase >/dev/null 2>&1; then
        IOS_LINK=$(distribute "$IPA_DEST" "$FIREBASE_IOS_APP_ID" "iOS IPA")
    else
        warn "Signed .ipa, FIREBASE_IOS_APP_ID or firebase CLI missing — skipping iOS distribution"
    fi
fi

# =============================================================================
step "Notify team"
# =============================================================================
TEAM_MSG="${APP_NAME} dev ${NEW_VERSION} (${NEW_BUILD}) — Android: ${ANDROID_LINK} | iOS: ${IOS_LINK}"
echo -e "${DIM}  Copy/paste:${NC}"
echo "  $TEAM_MSG"
notify "$TEAM_MSG"

# =============================================================================
# Summary
# =============================================================================
trap - EXIT
banner "DEV BUILD COMPLETE | v${NEW_VERSION} (${NEW_BUILD})"
print_step_table
echo ""
echo -e "${BOLD}  Artifacts${NC}"
[ -z "$APK_DEST" ] || printf "  %-8s %-46s %8s  sha256:%s\n" "Android" "${APK_DEST#$APP_DIR/}" "$(human_size "$APK_DEST")" "$(short_sha "$APK_DEST")"
[ -z "$IPA_DEST" ] || printf "  %-8s %-46s %8s  sha256:%s\n" "iOS" "${IPA_DEST#$APP_DIR/}" "$(human_size "$IPA_DEST")" "$(short_sha "$IPA_DEST")"
echo ""
[ "$DRY_RUN" = false ] || echo -e "  ${CYAN}Dry run: builds are real, distribution was simulated. pubspec.yaml unchanged.${NC}\n"
log "Done!"
