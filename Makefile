.PHONY: test test-relay test-app relay-bundle build-cli app release snapshots site

DERIVED_DATA := app/build
XCODEBUILD := xcodebuild -project app/Porchlight.xcodeproj -scheme Porchlight -destination "generic/platform=macOS" \
	-derivedDataPath $(DERIVED_DATA) -quiet

test: test-relay test-app

test-relay: relay/node_modules
	cd relay && npm test && npm run typecheck && npm run bundle:check

relay/node_modules: relay/package-lock.json
	cd relay && npm ci
	@touch $@

test-app:
	cd app/PorchlightCore && swift test

# The relay the app deploys: rebuild after changing relay/.
relay-bundle: relay/node_modules
	cd relay && npm run bundle

build-cli:
	cd app/PorchlightCore && swift build -c release --product porchlight-cli
	@echo "→ app/PorchlightCore/.build/release/porchlight-cli"

# Builds the menu bar app and opens it.
app:
	$(XCODEBUILD) -configuration Debug build
	open $(DERIVED_DATA)/Build/Products/Debug/Porchlight.app

# An optimized build, signed with your team if app/Config/Signing.local.xcconfig exists.
release:
	$(XCODEBUILD) -configuration Release build
	@codesign -dv $(DERIVED_DATA)/Build/Products/Release/Porchlight.app 2>&1 | grep -E "Authority=Developer|Signature=adhoc" || true
	@echo "→ $(DERIVED_DATA)/Build/Products/Release/Porchlight.app"

# Renders every screen with sample data, in light and dark, for design review.
snapshots:
	$(XCODEBUILD) -configuration Debug build
	rm -rf $(DERIVED_DATA)/snapshots
	PORCHLIGHT_SNAPSHOTS=$(CURDIR)/$(DERIVED_DATA)/snapshots $(DERIVED_DATA)/Build/Products/Debug/Porchlight.app/Contents/MacOS/Porchlight
	@echo "→ $(DERIVED_DATA)/snapshots"

# Publishes the website (docs/) to porchlight.sh.
site: relay/node_modules
	cd relay && npx wrangler deploy -c ../site/wrangler.jsonc
