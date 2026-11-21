#!/bin/bash
# =============================================================================
# PROD build: Flutter -> Google Play (.aab) + App Store Connect (.ipa)
# =============================================================================
# Usage:
#   ./scripts/build_prod.sh                 # bump patch+1, build+1, build & upload
#   ./scripts/build_prod.sh 2.7.2 173       # explicit version and build number
#   ./scripts/build_prod.sh --dry-run       # real local builds, SIMULATED uploads
#   ./scripts/build_prod.sh --skip-ios      # Android only
#   ./scripts/build_prod.sh --skip-android  # iOS only
#   ./scripts/build_prod.sh --skip-upload   # build artifacts, don't upload
#   ./scripts/build_prod.sh --no-clean      # skip `flutter clean` (faster)
#
# --dry-run needs no paid accounts:
#   Android: real signed release .aab (local keystore from .env)
#   iOS:     real release build with --no-codesign, packaged as an unsigned .ipa
#   Uploads: printed and simulated, never sent. pubspec.yaml is not modified.
#
# Real uploads need (all in .env, see .env.example):
#   Android: a Google Play service-account JSON + `gem install fastlane`
#   iOS:     an App Store Connect API key (.p8) + Apple Developer membership
#   Both uploads are non-releasing: builds land in the internal track /
#   TestFlight for you to add release notes and submit by hand.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"
SCRIPT_START=$(date +%s)

NEW_VERSION=""; NEW_BUILD=""
SKIP_IOS=false; SKIP_ANDROID=false; SKIP_UPLOAD=false; DRY_RUN=false; CLEAN=true

for arg in "$@"; do
    case $arg in
        --dry-run)      DRY_RUN=true ;;
        --skip-ios)     SKIP_IOS=true ;;
        --skip-android) SKIP_ANDROID=true ;;
        --skip-upload)  SKIP_UPLOAD=true ;;
        --no-clean)     CLEAN=false ;;
        -h|--help)      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)             echo "Unknown option: '$arg' (see --help)" >&2; exit 1 ;;
        *)  if [ -z "$NEW_VERSION" ]; then NEW_VERSION="$arg"
            elif [ -z "$NEW_BUILD" ]; then NEW_BUILD="$arg"; fi ;;
    esac
done

LOG_TAG="PROD"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
ACCENT="$MAGENTA"
trap on_error EXIT

if [ "$DRY_RUN" = true ]; then
    banner "PRODUCTION BUILD | DRY RUN (uploads simulated)"
else
    banner "PRODUCTION BUILD"
fi

# =============================================================================
step "Preflight checks"
# =============================================================================
load_env
APP_NAME="${APP_NAME:-app}"
ARTIFACT_DIR="$APP_DIR/${ARTIFACT_DIR:-dist}"
mkdir -p "$ARTIFACT_DIR"

require_tools flutter git
[ "$SKIP_ANDROID" = true ] || { require_tools java keytool; require_vars ANDROID_KEYSTORE_PATH ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; }
[ "$SKIP_ANDROID" = true ] || [ -f "$ANDROID_KEYSTORE_PATH" ] || die "Keystore not found at $ANDROID_KEYSTORE_PATH — run ./scripts/create_dummy_keystore.sh"
[ "$SKIP_IOS" = true ] || require_tools xcodebuild
[ -f config/prod.json ] || die "config/prod.json not found"
ok "Prod config: config/prod.json ($(grep -o '"API_BASE_URL": *"[^"]*"' config/prod.json | sed 's/.*": *"//; s/"$//'))"
check_branch "${PROD_BRANCH:-}"

# =============================================================================
step "Version management"
# =============================================================================
compute_version
write_version

# =============================================================================
step "Release safety check"
# =============================================================================
# Anything tagged DEV_ONLY (debug menus, test endpoints, disabled update
# prompts...) must never reach the stores. Fail the build instead of shipping it.
if grep -rn "DEV_ONLY" lib/ >/dev/null 2>&1; then
    grep -rn "DEV_ONLY" lib/ >&2
    die "DEV_ONLY code found in lib/ — remove it before a production build."
fi
ok "No DEV_ONLY code in lib/"

# =============================================================================
step "Clean & dependencies"
# =============================================================================
prepare_deps "$CLEAN"

BUILD_ARGS=(--release
    --build-name="$NEW_VERSION" --build-number="$NEW_BUILD"
    --dart-define-from-file=config/prod.json
    --dart-define=BUILD_VERSION="$NEW_VERSION+$NEW_BUILD")
BASENAME="${APP_NAME}-prod-v${NEW_VERSION}+${NEW_BUILD}"
AAB_DEST=""; IPA_DEST=""; IPA_SIGNED=false

# =============================================================================
if [ "$SKIP_ANDROID" = false ]; then
step "Android App Bundle (.aab)"
# =============================================================================
    flutter build appbundle "${BUILD_ARGS[@]}"
    AAB_DEST="$ARTIFACT_DIR/$BASENAME.aab"
    cp build/app/outputs/bundle/release/app-release.aab "$AAB_DEST"
    SIGNER=$(keytool -printcert -jarfile "$AAB_DEST" 2>/dev/null | grep -m1 "Owner:" | sed 's/^ *Owner: *//' || true)
    [ -n "$SIGNER" ] || die "The .aab is not signed — check the keystore settings in .env"
    ok "Signed by: $SIGNER"
    ok "Saved: ${AAB_DEST#$APP_DIR/} ($(human_size "$AAB_DEST"))"
fi

# =============================================================================
if [ "$SKIP_IOS" = false ]; then
step "iOS release build"
# =============================================================================
    if [ "$DRY_RUN" = false ] && [ -n "${IOS_EXPORT_OPTIONS_PLIST:-}" ]; then
        # Signed archive + App Store export (needs Apple Developer membership).
        flutter build ipa "${BUILD_ARGS[@]}" --export-options-plist="$IOS_EXPORT_OPTIONS_PLIST"
        IPA_DEST="$ARTIFACT_DIR/$BASENAME.ipa"
        cp "$(find build/ios/ipa -name '*.ipa' | head -1)" "$IPA_DEST"
        IPA_SIGNED=true
    else
        [ "$DRY_RUN" = true ] || warn "IOS_EXPORT_OPTIONS_PLIST not set — building unsigned"
        flutter build ios "${BUILD_ARGS[@]}" --no-codesign
        IPA_DEST="$ARTIFACT_DIR/$BASENAME-unsigned.ipa"
        rm -f "$IPA_DEST"
        package_unsigned_ipa "$APP_DIR/build/ios/iphoneos/Runner.app" "$IPA_DEST"
    fi
    ok "Saved: ${IPA_DEST#$APP_DIR/} ($(human_size "$IPA_DEST"))$([ "$IPA_SIGNED" = true ] || echo ' — unsigned')"
fi

# =============================================================================
ANDROID_STATUS="not uploaded"; IOS_STATUS="not uploaded"
if [ "$SKIP_UPLOAD" = true ]; then
    log "Skipping store uploads (--skip-upload)"
else
# =============================================================================
    if [ -n "$AAB_DEST" ]; then
        step "Upload to Google Play (internal track)"
        PLAY_CMD="fastlane supply --aab ${AAB_DEST#$APP_DIR/} --package_name ${ANDROID_PACKAGE_NAME:-<package>} --track internal --json_key $(mask "${PLAY_JSON_KEY_PATH:-}")"
        if [ "$DRY_RUN" = true ]; then
            dry "Would run: $PLAY_CMD"
            simulate_upload "Google Play" "$AAB_DEST" "${ANDROID_PACKAGE_NAME:-<package>} → internal track (not released)" \
                "Authenticating with service account..." "Authenticated" \
                "Creating edit..." "Edit created" \
                "Checking version code $NEW_BUILD is unused..." "Version code $NEW_BUILD is free"
            ANDROID_STATUS="dry run — simulated"
        elif [ -f "${PLAY_JSON_KEY_PATH:-/nonexistent}" ] && command -v fastlane >/dev/null 2>&1; then
            fastlane supply --aab "$AAB_DEST" --json_key "$PLAY_JSON_KEY_PATH" \
                --package_name "$ANDROID_PACKAGE_NAME" --track internal \
                --skip_upload_metadata true --skip_upload_changelogs true \
                --skip_upload_images true --skip_upload_screenshots true
            ANDROID_STATUS="uploaded — internal track"
        else
            warn "PLAY_JSON_KEY_PATH or fastlane missing — upload ${AAB_DEST#$APP_DIR/} by hand"
        fi
    fi

    if [ -n "$IPA_DEST" ]; then
        step "Upload to App Store Connect (TestFlight)"
        ASC_CMD="xcrun altool --upload-app -t ios -f ${IPA_DEST#$APP_DIR/} --apiKey $(mask "${ASC_KEY_ID:-}") --apiIssuer $(mask "${ASC_ISSUER_ID:-}")"
        if [ "$DRY_RUN" = true ]; then
            dry "Would run: $ASC_CMD"
            dry "A real upload needs a signed .ipa — this one is unsigned (no Apple Developer account)"
            simulate_upload "App Store Connect" "$IPA_DEST" "${IOS_BUNDLE_ID:-<bundle id>} → TestFlight (not submitted)" \
                "Authenticating with App Store Connect API key..." "Authenticated" \
                "Validating bundle id, version and build number..." "Package metadata is valid" \
                "Checking build $NEW_VERSION ($NEW_BUILD) is not already on TestFlight..." "Build number is free"
            IOS_STATUS="dry run — simulated"
        elif [ "$IPA_SIGNED" = true ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
            # altool looks for AuthKey_<ASC_KEY_ID>.p8 in ./private_keys or ~/.appstoreconnect/private_keys
            xcrun altool --upload-app -t ios -f "$IPA_DEST" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
            IOS_STATUS="uploaded — TestFlight"
        else
            warn "Signed .ipa or ASC_KEY_ID / ASC_ISSUER_ID missing — upload ${IPA_DEST#$APP_DIR/} with Transporter"
        fi
    fi
fi

# =============================================================================
step "Changelog"
# =============================================================================
CHANGELOG="$ARTIFACT_DIR/$BASENAME-CHANGELOG.md"
if is_git_repo && git rev-parse -q --verify HEAD >/dev/null; then
    PREV_TAG=$(git describe --tags --abbrev=0 --match 'prod-v*' 2>/dev/null || true)
    RANGE=${PREV_TAG:+$PREV_TAG..}HEAD
    {
        echo "# ${APP_NAME} v${NEW_VERSION} (${NEW_BUILD})"
        echo
        echo "_Changes since ${PREV_TAG:-the first commit}._"
        echo
        # Play Store release notes max out at 500 characters.
        git log --no-merges --pretty=format:"- %s" "$RANGE" | awk '
            { if (total + length($0) + 1 > 480) { print "- ...and more improvements"; exit }
              print; total += length($0) + 1 }'
        echo
    } > "$CHANGELOG"
    ok "Changelog: ${CHANGELOG#$APP_DIR/}"
    sed 's/^/    /' "$CHANGELOG"
else
    CHANGELOG=""
    warn "No git history yet — skipping changelog"
fi

# =============================================================================
step "Notify team"
# =============================================================================
MODE=$([ "$DRY_RUN" = true ] && echo " (dry run)" || echo "")
notify "${APP_NAME} prod build v${NEW_VERSION} (${NEW_BUILD}) is ready${MODE} — built in $(fmt_secs $(( $(date +%s) - SCRIPT_START )))"

# =============================================================================
# Summary
# =============================================================================
trap - EXIT
banner "PROD BUILD COMPLETE | v${NEW_VERSION} (${NEW_BUILD})"
print_step_table
echo ""
echo -e "${BOLD}  Artifacts${NC}"
[ -z "$AAB_DEST" ] || printf "  %-8s %-46s %8s  sha256:%s  ${GREEN}[%s]${NC}\n" "Android" "${AAB_DEST#$APP_DIR/}" "$(human_size "$AAB_DEST")" "$(short_sha "$AAB_DEST")" "$ANDROID_STATUS"
[ -z "$IPA_DEST" ] || printf "  %-8s %-46s %8s  sha256:%s  ${GREEN}[%s]${NC}\n" "iOS" "${IPA_DEST#$APP_DIR/}" "$(human_size "$IPA_DEST")" "$(short_sha "$IPA_DEST")" "$IOS_STATUS"
[ -z "$CHANGELOG" ] || printf "  %-8s %s\n" "Notes" "${CHANGELOG#$APP_DIR/}"
echo ""
if [ "$DRY_RUN" = true ]; then
    echo -e "  ${CYAN}Dry run: builds are real, store uploads were simulated. pubspec.yaml unchanged.${NC}"
else
    echo -e "${BOLD}  Next steps${NC}"
    echo "  1. Add release notes in Play Console and App Store Connect"
    echo "  2. Promote the internal track / submit the TestFlight build for review"
    echo "  3. Commit the version bump and tag it: git tag prod-v${NEW_VERSION}+${NEW_BUILD}"
fi
echo ""
log "Done!"
