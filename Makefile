.PHONY: site test test-relay test-app build-cli app release snapshots dev relay-bundle

DERIVED_DATA := app/build

test: test-relay test-app

test-relay:
	cd relay && npm test && npx tsc --noEmit && node scripts/bundle.mjs --check

# The relay the app deploys: rebuild after changing relay/.
relay-bundle:
	cd relay && npm run bundle

test-app:
	cd app/PorchlightCore && swift test

build-cli:
	cd app/PorchlightCore && swift build -c release --product porchlight-cli
	@echo "→ app/PorchlightCore/.build/release/porchlight-cli"

# Builds the menubar app with Xcode and opens it.
app:
	xcodebuild -project app/Porchlight.xcodeproj -scheme Porchlight -configuration Debug -destination "generic/platform=macOS" \
		-derivedDataPath $(DERIVED_DATA) -quiet build
	open $(DERIVED_DATA)/Build/Products/Debug/Porchlight.app

# An optimized build, signed with your team if app/Config/Signing.local.xcconfig exists.
release:
	xcodebuild -project app/Porchlight.xcodeproj -scheme Porchlight -configuration Release -destination "generic/platform=macOS" \
		-derivedDataPath $(DERIVED_DATA) -quiet build
	@codesign -dv $(DERIVED_DATA)/Build/Products/Release/Porchlight.app 2>&1 | grep -E "Authority=Developer|Signature=adhoc" || true
	@echo "→ $(DERIVED_DATA)/Build/Products/Release/Porchlight.app"

# Renders every screen with sample data, in light and dark, for design review.
# Publish the website (docs/) to porchlight.sh.
site:
	cd relay && npx wrangler deploy -c ../site/wrangler.jsonc

snapshots:
	xcodebuild -project app/Porchlight.xcodeproj -scheme Porchlight -configuration Debug -destination "generic/platform=macOS" \
		-derivedDataPath $(DERIVED_DATA) -quiet build
	rm -rf $(DERIVED_DATA)/snapshots
	PORCHLIGHT_SNAPSHOTS=$(CURDIR)/$(DERIVED_DATA)/snapshots $(DERIVED_DATA)/Build/Products/Debug/Porchlight.app/Contents/MacOS/Porchlight
	@echo "→ $(DERIVED_DATA)/snapshots"

dev:
	cd relay && npx wrangler dev
