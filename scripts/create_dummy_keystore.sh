#!/bin/bash
# =============================================================================
# Creates a throwaway Android release keystore for local/demo builds.
# Free, local, never uploaded. For a real app, generate your own keystore
# once, back it up somewhere safe, and NEVER commit it.
# =============================================================================
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

if [ ! -f .env ]; then
    cp .env.example .env
    echo "Created .env from .env.example"
fi
set -a; . ./.env; set +a

KEYSTORE="${ANDROID_KEYSTORE_PATH:-android/dummy-release.jks}"
if [ -f "$KEYSTORE" ]; then
    echo "Keystore already exists at $KEYSTORE — leaving it alone."
    exit 0
fi

keytool -genkeypair -v \
    -keystore "$KEYSTORE" \
    -storetype PKCS12 \
    -alias "$ANDROID_KEY_ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$ANDROID_KEYSTORE_PASSWORD" \
    -keypass "$ANDROID_KEY_PASSWORD" \
    -dname "CN=Build Demo, OU=Demo, O=Example, L=Nowhere, C=US" 2>&1 | tail -1

echo "Dummy keystore created at $KEYSTORE (gitignored)"
