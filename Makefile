.PHONY: test test-relay test-app build-cli app release dev relay-bundle

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

dev:
	cd relay && npx wrangler dev
