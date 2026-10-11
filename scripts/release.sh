#!/bin/bash
# Builds a release of Porchlight: signed, notarized, zipped, with its Homebrew cask.
#
#   scripts/release.sh 0.1.0              # build only; outputs in app/build/release
#   scripts/release.sh 0.1.0 --publish    # also create the GitHub release and update the tap
#
# Needs: Developer ID signing (app/Config/Signing.local.xcconfig) and, to notarize, a
# notarytool keychain profile named by NOTARY_PROFILE (default "porchlight-notary"):
#   xcrun notarytool store-credentials porchlight-notary --apple-id you@example.com --team-id ABCDE12345
# Publishing needs the GitHub CLI (gh), logged in.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version> [--publish]}
PUBLISH=${2:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-porchlight-notary}
TAP_REPO=${TAP_REPO:-git@github.com:strazan/homebrew-tap.git}

cd "$(dirname "$0")/.."
OUT=app/build/release
APP=app/build/Build/Products/Release/Porchlight.app
ZIP=$OUT/Porchlight-$VERSION.zip
rm -rf "$OUT" && mkdir -p "$OUT"

if [ "$PUBLISH" = "--publish" ] && [ -n "$(git status --porcelain)" ]; then
  echo "error: commit your changes before publishing" >&2; exit 1
fi

echo "→ building $VERSION"
make -s relay-bundle >/dev/null
xcodebuild -project app/Porchlight.xcodeproj -scheme Porchlight -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath app/build -quiet \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" build

codesign --verify --deep --strict "$APP"
# Captured first: with pipefail, grep -q exiting early would fail codesign with SIGPIPE.
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
if [[ "$SIGNATURE" != *"Authority=Developer ID Application"* ]]; then
  echo "error: not signed with a Developer ID (see app/Config/Base.xcconfig)" >&2; exit 1
fi

zip_app() { rm -f "$ZIP"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"; }
zip_app

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "→ notarizing (a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  zip_app
  spctl --assess --type execute --verbose "$APP"
else
  echo "warning: no notarytool profile '$NOTARY_PROFILE'; the app is NOT notarized" >&2
  [ "$PUBLISH" = "--publish" ] && { echo "error: refusing to publish an unnotarized build" >&2; exit 1; }
fi

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{SHA256}}/$SHA/g" scripts/porchlight.rb.template > "$OUT/porchlight.rb"
echo "→ $ZIP"
echo "→ $OUT/porchlight.rb (sha256 $SHA)"

if [ "$PUBLISH" = "--publish" ]; then
  echo "→ publishing v$VERSION"
  git tag "v$VERSION" && git push origin "v$VERSION"
  # Also as Porchlight.zip, so the website can link to releases/latest/download/Porchlight.zip.
  cp "$ZIP" "$OUT/Porchlight.zip"
  gh release create "v$VERSION" "$ZIP" "$OUT/Porchlight.zip" --title "Porchlight $VERSION" --generate-notes
  TAP=$(mktemp -d)
  git clone -q "$TAP_REPO" "$TAP"
  mkdir -p "$TAP/Casks" && cp "$OUT/porchlight.rb" "$TAP/Casks/porchlight.rb"
  (cd "$TAP" && git add Casks/porchlight.rb && git commit -qm "porchlight $VERSION" && git push -q)
  echo "→ brew install --cask strazan/tap/porchlight"
fi
