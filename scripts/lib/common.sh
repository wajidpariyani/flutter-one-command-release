#!/bin/bash
# =============================================================================
# Shared helpers for build_dev.sh and build_prod.sh
# Bash 3.2 compatible (the default /bin/bash on macOS).
# =============================================================================

# ---- Colors ------------------------------------------------------------------
if [ -t 1 ] || [ -n "${FORCE_COLOR:-}" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'; CYAN=$'\033[0;36m'
    DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; DIM=''; BOLD=''; NC=''
fi

# Set by the calling script before sourcing helpers that print.
LOG_TAG="${LOG_TAG:-BUILD}"
ACCENT="${ACCENT:-$BLUE}"
DRY_RUN="${DRY_RUN:-false}"

log()  { echo -e "${ACCENT}[${LOG_TAG}]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✔${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
die()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
dry()  { echo -e "${CYAN}[DRY RUN]${NC} $1"; }

banner() {
    local line="══════════════════════════════════════════════════════════════"
    echo ""
    echo -e "${ACCENT}╔${line}╗${NC}"
    printf "${ACCENT}║${NC}${BOLD}  %-60s${NC}${ACCENT}║${NC}\n" "$1"
    echo -e "${ACCENT}╚${line}╝${NC}"
    echo ""
}

# ---- Step timing -------------------------------------------------------------
# Each step() closes the previous one and records its duration for the summary.
STEP_NAMES=()
STEP_SECS=()
STEP_NO=0
_STEP_START=""
_CURRENT_STEP=""

_close_step() {
    if [ -n "$_CURRENT_STEP" ]; then
        STEP_NAMES+=("$_CURRENT_STEP")
        STEP_SECS+=($(( $(date +%s) - _STEP_START )))
        _CURRENT_STEP=""
    fi
}

step() {
    _close_step
    STEP_NO=$((STEP_NO + 1))
    _CURRENT_STEP="$1"
    _STEP_START=$(date +%s)
    echo ""
    echo -e "${ACCENT}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${ACCENT}${BOLD} ${STEP_NO}. $1${NC}"
    echo -e "${ACCENT}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

fmt_secs() {
    local s=$1
    if [ "$s" -ge 60 ]; then printf "%dm %02ds" $((s / 60)) $((s % 60)); else printf "%ds" "$s"; fi
}

print_step_table() {
    _close_step
    local i
    for i in "${!STEP_NAMES[@]}"; do
        printf "  ${GREEN}✔${NC} %-44s %10s\n" "${STEP_NAMES[$i]}" "$(fmt_secs "${STEP_SECS[$i]}")"
    done
    printf "  ${BOLD}%-46s %10s${NC}\n" "Total" "$(fmt_secs $(( $(date +%s) - SCRIPT_START )))"
}

# If the script dies mid-step, say which step failed.
on_error() {
    local code=$?
    if [ $code -ne 0 ] && [ -n "$_CURRENT_STEP" ]; then
        echo -e "\n${RED}✘ Failed during step: ${_CURRENT_STEP} (exit $code)${NC}" >&2
    fi
}

# ---- Environment -------------------------------------------------------------
# Loads $APP_DIR/.env (gitignored). Every secret in this project lives there.
load_env() {
    if [ ! -f "$APP_DIR/.env" ]; then
        die ".env not found. Run:\n    cp .env.example .env\n    ./scripts/create_dummy_keystore.sh"
    fi
    set -a
    # shellcheck disable=SC1091
    . "$APP_DIR/.env"
    set +a
    # Gradle resolves relative paths from android/app, so hand it an absolute one.
    if [ -n "${ANDROID_KEYSTORE_PATH:-}" ]; then
        case "$ANDROID_KEYSTORE_PATH" in
            /*) ;;
            *) ANDROID_KEYSTORE_PATH="$APP_DIR/$ANDROID_KEYSTORE_PATH" ;;
        esac
        export ANDROID_KEYSTORE_PATH
    fi
}

require_vars() {
    local missing="" v
    for v in "$@"; do
        [ -n "${!v:-}" ] || missing="$missing $v"
    done
    [ -z "$missing" ] || die "Missing in .env:${missing}"
}

require_tools() {
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || die "'$t' is not installed or not on PATH."
        ok "$t"
    done
}

# Show the last 2 characters of a secret, mask the rest.
mask() {
    local s="${1:-}"
    if [ ${#s} -le 2 ]; then echo "****"; else echo "****${s: -2}"; fi
}

# ---- Git ---------------------------------------------------------------------
is_git_repo() { git -C "$APP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

check_branch() {
    local required="$1"
    if [ -z "$required" ]; then
        log "No required branch configured — skipping branch check"
    elif ! is_git_repo; then
        warn "Not a git repository — skipping branch check (expected '$required')"
    else
        local current
        current=$(git -C "$APP_DIR" branch --show-current)
        [ "$current" = "$required" ] || die "Must be on '$required' branch. Currently on '$current'."
        ok "On branch: $current"
    fi
}

# ---- Versioning --------------------------------------------------------------
# Sets CURRENT_VERSION, CURRENT_BUILD, NEW_VERSION, NEW_BUILD.
# Auto-bump = patch + 1 and build + 1, unless explicit values were passed.
compute_version() {
    local line
    line=$(grep "^version:" "$APP_DIR/pubspec.yaml" | sed 's/version: *//')
    CURRENT_VERSION=$(echo "$line" | cut -d'+' -f1)
    CURRENT_BUILD=$(echo "$line" | cut -s -d'+' -f2)
    CURRENT_BUILD=${CURRENT_BUILD:-0}
    if [ -z "${NEW_VERSION:-}" ]; then
        local major minor patch
        IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"
        NEW_VERSION="$major.$minor.$((patch + 1))"
    fi
    NEW_BUILD=${NEW_BUILD:-$((CURRENT_BUILD + 1))}
    log "Current version: $CURRENT_VERSION+$CURRENT_BUILD"
    log "New version:     ${BOLD}$NEW_VERSION+$NEW_BUILD${NC}"
}

write_version() {
    if [ "$DRY_RUN" = true ]; then
        dry "pubspec.yaml left unchanged (version passed via --build-name / --build-number)"
    else
        sed -i '' "s/^version: .*/version: $NEW_VERSION+$NEW_BUILD/" "$APP_DIR/pubspec.yaml"
        ok "pubspec.yaml updated to $NEW_VERSION+$NEW_BUILD"
    fi
}

# ---- Dependencies ------------------------------------------------------------
prepare_deps() {
    local clean="$1"
    if [ "$clean" = true ]; then
        flutter clean
    else
        log "Skipping flutter clean (--no-clean)"
    fi
    flutter pub get
    if [ -f "$APP_DIR/ios/Podfile" ] && [ "${SKIP_IOS:-false}" = false ]; then
        (cd "$APP_DIR/ios" && pod install)
    fi
    if grep -q "build_runner" "$APP_DIR/pubspec.yaml"; then
        dart run build_runner build --delete-conflicting-outputs
    fi
}

# ---- Artifacts ---------------------------------------------------------------
human_size() {
    local bytes
    bytes=$(stat -f%z "$1")
    awk -v b="$bytes" 'BEGIN { if (b >= 1048576) printf "%.1f MB", b/1048576; else printf "%.0f KB", b/1024 }'
}

short_sha() { shasum -a 256 "$1" | cut -c1-12; }

# Bundle an unsigned Runner.app into an .ipa so the artifact (and its size) is real.
package_unsigned_ipa() {
    local app="$1" out="$2" tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/Payload"
    cp -R "$app" "$tmp/Payload/"
    (cd "$tmp" && zip -qry "$out" Payload)
    rm -rf "$tmp"
}

# ---- Dry-run upload simulation ----------------------------------------------
# Clearly labelled [DRY RUN]: nothing leaves this machine. Sizes are the real
# artifact's size so the output matches what a real upload would look like.
# DRY_RUN_FAST=1 skips the animation (useful for CI / quick checks).
_pause() { [ -n "${DRY_RUN_FAST:-}" ] || sleep "$1"; }

_progress_bar() {
    local label="$1" bytes="$2" width=30 pct filled done_mb total_mb
    total_mb=$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b/1048576 }')
    for pct in 0 4 9 15 22 30 38 47 55 63 70 78 85 91 96 100; do
        filled=$((pct * width / 100))
        done_mb=$(awk -v b="$bytes" -v p="$pct" 'BEGIN { printf "%.1f", b*p/100/1048576 }')
        printf "\r${CYAN}[DRY RUN]${NC} %s [%s%s] %3d%%  %s / %s MB" \
            "$label" \
            "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
            "$(printf '%*s' $((width - filled)) '' | tr ' ' '.')" \
            "$pct" "$done_mb" "$total_mb"
        _pause 0.12
    done
    echo ""
}

simulate_upload() {
    # $1 = store label, $2 = file, $3 = destination description, rest = stage lines
    local store="$1" file="$2" dest="$3" bytes
    shift 3
    bytes=$(stat -f%z "$file")
    dry "${BOLD}SIMULATED upload — no network calls, no account needed${NC}"
    dry "Target: $dest"
    _pause 0.4
    while [ $# -gt 1 ]; do
        dry "$1"; _pause 0.5
        ok "$2"
        shift 2
    done
    _progress_bar "Uploading $(basename "$file")" "$bytes"
    _pause 0.3
    dry "$store would now process build $NEW_VERSION ($NEW_BUILD)"
    ok "Dry run complete for $store"
}

# ---- Notifications -----------------------------------------------------------
# Optional and free: a Discord or Slack incoming-webhook URL in .env.
notify() {
    local msg="$1"
    if [ -z "${NOTIFY_WEBHOOK_URL:-}" ]; then
        log "NOTIFY_WEBHOOK_URL not set — skipping team notification"
        return 0
    fi
    local payload
    payload=$(printf '{"content": "%s", "text": "%s"}' "$msg" "$msg")
    if curl -fsS -X POST -H "Content-Type: application/json" -d "$payload" "$NOTIFY_WEBHOOK_URL" >/dev/null; then
        ok "Team notified via webhook"
    else
        warn "Webhook notification failed (build itself succeeded)"
    fi
}
