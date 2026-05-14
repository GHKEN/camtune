#!/bin/bash
# Build camtune.app + embedded CameraExtension.systemextension.
#
# Usage:
#   ./build.sh          # build (release)
#   ./build.sh debug    # build (debug, faster compile)
#   ./build.sh run      # build and launch
#   ./build.sh clean    # remove camtune.app and build artifacts

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="camtune"
APP_BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.ghken.camtune"
EXT_NAME="CameraExtension"
EXT_BUNDLE_ID="com.ghken.camtune.CameraExtension"
EXT_BUNDLE_NAME="${EXT_BUNDLE_ID}.systemextension"
MIN_MACOS="13.0"

MODE="${1:-release}"
# Default: ad-hoc signing (works for the host app & Phase 1/2 features only).
# For System Extension install, set SIGN_IDENTITY to a Developer ID Application:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
TIMESTAMP_FLAG=""
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    TIMESTAMP_FLAG="--timestamp"
fi

if [[ "$MODE" == "clean" ]]; then
    rm -rf "${APP_BUNDLE}" .build
    echo "✅ cleaned"
    exit 0
fi

ARCH=$(uname -m)
TARGET="${ARCH}-apple-macos${MIN_MACOS}"

OPT_FLAGS=()
if [[ "$MODE" == "debug" || "$MODE" == "run" ]]; then
    OPT_FLAGS+=(-Onone -g)
else
    OPT_FLAGS+=(-O)
fi

# ---------- Fresh bundle layout ----------
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
EXT_PATH="${APP_BUNDLE}/Contents/Library/SystemExtensions/${EXT_BUNDLE_NAME}"
mkdir -p "${EXT_PATH}/Contents/MacOS"
mkdir -p "${EXT_PATH}/Contents/Resources"

# ---------- Compile Camera Extension ----------
echo "🔨 Compiling CameraExtension (${TARGET}, ${MODE})..."

EXT_SOURCES=()
while IFS= read -r -d '' f; do
    EXT_SOURCES+=("$f")
done < <(find Sources/CameraExtension Sources/Shared -name "*.swift" -type f -print0)

swiftc \
    -target "${TARGET}" \
    -module-name "${EXT_NAME}" \
    "${OPT_FLAGS[@]}" \
    -o "${EXT_PATH}/Contents/MacOS/${EXT_NAME}" \
    "${EXT_SOURCES[@]}"

cp Resources/extension/Info.plist "${EXT_PATH}/Contents/Info.plist"
printf 'SYSX????' > "${EXT_PATH}/Contents/PkgInfo"

# Bump CFBundleVersion to force sysextd to replace any installed instance with
# this new build (sysextd skips activation if the version hasn't changed).
BUILD_NUM=$(date +%Y%m%d%H%M%S)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUM}" "${EXT_PATH}/Contents/Info.plist"

# Embed extension's provisioning profile (required because the extension uses
# managed entitlements like com.apple.security.application-groups).
if [[ -f extension.provisionprofile ]]; then
    cp extension.provisionprofile "${EXT_PATH}/Contents/embedded.provisionprofile"
    echo "📎 Embedded extension provisioning profile"
fi

# Sign the extension FIRST (inner-to-outer signing order)
codesign --force --sign "${SIGN_IDENTITY}" \
    --identifier "${EXT_BUNDLE_ID}" \
    --entitlements Resources/extension/extension.entitlements \
    --options runtime \
    ${TIMESTAMP_FLAG} \
    "${EXT_PATH}"

# ---------- Compile host app ----------
echo "🔨 Compiling host app (${TARGET}, ${MODE})..."

APP_SOURCES=()
while IFS= read -r -d '' f; do
    APP_SOURCES+=("$f")
done < <(find Sources/camtune Sources/Shared -name "*.swift" -type f -print0)

swiftc \
    -target "${TARGET}" \
    -parse-as-library \
    "${OPT_FLAGS[@]}" \
    -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
    "${APP_SOURCES[@]}"

cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUM}" "${APP_BUNDLE}/Contents/Info.plist"

# Embed Developer ID provisioning profile if present (required when the host
# uses managed entitlements like com.apple.developer.system-extension.install).
if [[ -f embedded.provisionprofile ]]; then
    cp embedded.provisionprofile "${APP_BUNDLE}/Contents/embedded.provisionprofile"
    echo "📎 Embedded provisioning profile"
fi

# Sign the host app LAST (outer)
codesign --force --sign "${SIGN_IDENTITY}" \
    --identifier "${BUNDLE_ID}" \
    --entitlements Resources/camtune.entitlements \
    --options runtime \
    ${TIMESTAMP_FLAG} \
    "${APP_BUNDLE}"

echo ""
echo "✅ Built ${APP_BUNDLE}"
echo "   └── Contents/Library/SystemExtensions/${EXT_BUNDLE_NAME}"
echo ""
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    echo "⚠  ad-hoc signed. System Extension のインストールは不可。"
    echo "    SIGN_IDENTITY=\"Developer ID Application: ...\" ./build.sh && ./notarize.sh"
else
    echo "Signed with: ${SIGN_IDENTITY}"
    echo "Next: ./notarize.sh   (Apple に提出して公証を取得 + staple)"
fi

if [[ "$MODE" == "run" ]]; then
    echo ""
    echo "🚀 Launching..."
    open "${APP_BUNDLE}"
fi

if [[ "$MODE" == "install" ]]; then
    echo ""
    echo "📂 Installing to /Applications (required for System Extension activation)..."
    # Stop any running instance first to release the bundle
    pkill -f "/Applications/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/${APP_BUNDLE}"
    cp -R "${APP_BUNDLE}" "/Applications/${APP_BUNDLE}"
    echo "🚀 Launching /Applications/${APP_BUNDLE}..."
    open "/Applications/${APP_BUNDLE}"
fi
