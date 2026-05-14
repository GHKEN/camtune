#!/bin/bash
# Submit camtune.app to Apple's notarization service and staple the ticket.
#
# Prerequisites (one-time):
#   1. Have a "Developer ID Application" certificate in Keychain
#      (https://developer.apple.com/account/resources/certificates)
#   2. Build the app with that identity:
#        SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
#   3. Create an app-specific password at https://appleid.apple.com/account/manage
#   4. Store credentials once:
#        xcrun notarytool store-credentials AC_NOTARY \
#            --apple-id "you@example.com" \
#            --team-id  "TEAMID" \
#            --password "<app-specific-password>"
#
# Usage:
#   ./notarize.sh                      # uses keychain profile "AC_NOTARY"
#   NOTARY_PROFILE=other ./notarize.sh # uses a different stored profile

set -euo pipefail
cd "$(dirname "$0")"

APP_BUNDLE="camtune.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
ZIP_PATH="camtune-notarize.zip"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "❌ ${APP_BUNDLE} not found. Run ./build.sh first."
    exit 1
fi

# Verify signing is not ad-hoc
SIG_INFO=$(codesign -dv "${APP_BUNDLE}" 2>&1 || true)
if echo "${SIG_INFO}" | grep -q "Signature=adhoc"; then
    echo "❌ ${APP_BUNDLE} is ad-hoc signed. Re-build with SIGN_IDENTITY set."
    exit 1
fi

echo "📦 Packaging ${APP_BUNDLE}..."
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

echo "☁️ Submitting to Apple Notary Service (this may take a few minutes)..."
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo "📎 Stapling ticket..."
xcrun stapler staple "${APP_BUNDLE}"

echo "🔍 Validating..."
xcrun stapler validate "${APP_BUNDLE}"
spctl -a -t exec -vv "${APP_BUNDLE}" || true

rm -f "${ZIP_PATH}"
echo "✅ Notarized & stapled"
