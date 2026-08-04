# MacQ release pipeline
#
#   make build          compile a universal Release .app (unsigned)
#   make sign           codesign it with Developer ID + hardened runtime
#   make notarize       submit to Apple, wait for the ticket, staple it
#   make dmg            wrap the stapled app in a distributable .dmg
#   make notarize-dmg   notarize and staple the .dmg itself
#   make release        all of the above, in order
#
# Signing material and credentials live in secrets/ and are never committed.
# Copy secrets/config.mk.example to secrets/config.mk and fill it in, then run
# `make doctor` to check the setup.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# --------------------------------------------------------------- project ---

XCODE_PROJECT := app/MacQ.xcodeproj
SCHEME        := MacQ
CONFIGURATION := Release
APP_NAME      := MacQ

# build/ holds intermediates (DerivedData, DMG staging, notary receipts);
# artifacts/ holds only the finished, shippable output. Both are ignored by git.
BUILD_DIR     := build
ARTIFACTS_DIR := artifacts
DERIVED_DATA  := $(BUILD_DIR)/DerivedData
STAGE_DIR     := $(BUILD_DIR)/dmg
SECRETS_DIR   := secrets

# Local, uncommitted configuration: signing identity and notary credentials.
-include $(SECRETS_DIR)/config.mk

# Version defaults to what the Xcode project declares; change it with
# ./set_version.sh 1.2.0 ++ and check it with `make version`. Override on the
# command line (make release VERSION=1.2.0 BUILD_NUMBER=42) or in
# secrets/config.mk. The tr strips the quotes Xcode adds around values that are
# not plain dotted numbers.
VERSION ?= $(shell sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);/\1/p' $(XCODE_PROJECT)/project.pbxproj | head -1 | tr -d '"')
ifeq ($(strip $(VERSION)),)
VERSION := 0.0.0
endif

BUILD_NUMBER ?= $(shell sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' $(XCODE_PROJECT)/project.pbxproj | head -1 | tr -d '"')
ifeq ($(strip $(BUILD_NUMBER)),)
BUILD_NUMBER := 1
endif

APP        := $(ARTIFACTS_DIR)/$(APP_NAME).app
DMG        := $(ARTIFACTS_DIR)/$(APP_NAME)-$(VERSION).dmg
ZIP        := $(ARTIFACTS_DIR)/$(APP_NAME)-$(VERSION).zip
NOTARY_ZIP := $(BUILD_DIR)/$(APP_NAME)-notarize.zip
VOLNAME    := $(APP_NAME) $(VERSION)

# auto | create-dmg | hdiutil
DMG_TOOL ?= auto

# Temporary keychain used by `make keychain-import` (CI); harmless locally.
KEYCHAIN_NAME     ?= macq-build.keychain-db
KEYCHAIN_PASSWORD ?= macq-build

# --------------------------------------------------------------- signing ---

# The app is signed here rather than by Xcode, so the project itself stays
# ad-hoc/unsigned and needs no per-machine team settings. Hardened runtime and
# the secure timestamp are required for notarization.
KEYCHAIN_FLAG    := $(if $(strip $(CODESIGN_KEYCHAIN)),--keychain "$(CODESIGN_KEYCHAIN)",)
ENTITLEMENTS_FLAG := $(if $(strip $(ENTITLEMENTS)),--entitlements "$(ENTITLEMENTS)",)
CODESIGN_FLAGS   := --force --options runtime --timestamp --sign "$(SIGN_IDENTITY)" $(KEYCHAIN_FLAG)

# Notary credentials, in order of preference: stored keychain profile, App Store
# Connect API key, then Apple ID + app-specific password.
ifneq ($(strip $(NOTARY_KEYCHAIN_PROFILE)),)
NOTARY_AUTH := --keychain-profile "$(NOTARY_KEYCHAIN_PROFILE)"
NOTARY_AUTH_DESC := keychain profile "$(NOTARY_KEYCHAIN_PROFILE)"
else ifneq ($(strip $(ASC_API_KEY_FILE)),)
NOTARY_AUTH := --key "$(ASC_API_KEY_FILE)" --key-id "$(ASC_API_KEY_ID)" --issuer "$(ASC_API_ISSUER_ID)"
NOTARY_AUTH_DESC := App Store Connect API key $(ASC_API_KEY_ID)
else ifneq ($(strip $(APPLE_ID)),)
NOTARY_AUTH := --apple-id "$(APPLE_ID)" --password "$(APPLE_APP_PASSWORD)" --team-id "$(TEAM_ID)"
NOTARY_AUTH_DESC := Apple ID $(APPLE_ID)
else
NOTARY_AUTH :=
NOTARY_AUTH_DESC := (none configured)
endif

define require_var
@if [ -z "$(strip $($(1)))" ]; then \
	echo "error: $(1) is not set."; \
	echo "       Set it in $(SECRETS_DIR)/config.mk (see $(SECRETS_DIR)/config.mk.example)."; \
	exit 1; \
fi
endef

define require_notary
@if [ -z '$(strip $(NOTARY_AUTH))' ]; then \
	echo "error: no notarization credentials configured."; \
	echo "       Set NOTARY_KEYCHAIN_PROFILE, or ASC_API_KEY_FILE/ASC_API_KEY_ID/ASC_API_ISSUER_ID,"; \
	echo "       or APPLE_ID/APPLE_APP_PASSWORD/TEAM_ID in $(SECRETS_DIR)/config.mk."; \
	exit 1; \
fi
endef

define require_app
@if [ ! -d "$(APP)" ]; then \
	echo "error: $(APP) not found - run 'make build' first."; \
	exit 1; \
fi
endef

# ----------------------------------------------------------------- build ---

.PHONY: build
build: ## Compile a universal Release .app (unsigned) into artifacts/
	@echo "==> Building $(APP_NAME) $(VERSION) ($(BUILD_NUMBER)), configuration $(CONFIGURATION)"
	@mkdir -p "$(ARTIFACTS_DIR)"
	@xcodebuild \
		-project "$(XCODE_PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination 'generic/platform=macOS' \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY="" \
		MARKETING_VERSION="$(VERSION)" \
		CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" \
		build
	@rm -rf "$(APP)"
	@ditto "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app" "$(APP)"
	@echo "==> Built $(APP)"
	@lipo -archs "$(APP)/Contents/MacOS/$(APP_NAME)" | sed 's/^/    architectures: /'

# ------------------------------------------------------------------ sign ---

.PHONY: sign
sign: ## Codesign the .app with Developer ID (hardened runtime + timestamp)
	$(call require_var,SIGN_IDENTITY)
	$(call require_app)
	@echo "==> Signing $(APP) as $(SIGN_IDENTITY)"
	@xattr -cr "$(APP)"
	@if [ -n "$(strip $(PROVISIONING_PROFILE))" ]; then \
		if [ ! -f "$(PROVISIONING_PROFILE)" ]; then \
			echo "error: PROVISIONING_PROFILE not found: $(PROVISIONING_PROFILE)"; exit 1; \
		fi; \
		echo "    embedding $(PROVISIONING_PROFILE)"; \
		cp "$(PROVISIONING_PROFILE)" "$(APP)/Contents/embedded.provisionprofile"; \
	fi
	@set -eo pipefail; \
	 find "$(APP)/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 | \
	 while IFS= read -r -d '' f; do echo "    nested: $$f"; codesign $(CODESIGN_FLAGS) "$$f"; done
	@set -eo pipefail; \
	 find "$(APP)/Contents" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \
		-o -name '*.appex' -o -name '*.bundle' \) -print0 | \
	 while IFS= read -r -d '' f; do echo "    nested: $$f"; codesign $(CODESIGN_FLAGS) "$$f"; done
	@codesign $(CODESIGN_FLAGS) $(ENTITLEMENTS_FLAG) "$(APP)"
	@codesign --verify --deep --strict --verbose=2 "$(APP)"
	@echo "==> Signed."

# -------------------------------------------------------------- notarize ---

.PHONY: notarize
notarize: ## Submit the signed .app to Apple, wait, then staple the ticket
	$(call require_notary)
	$(call require_app)
	@if ! codesign --verify --strict "$(APP)" >/dev/null 2>&1; then \
		echo "error: $(APP) is not validly signed - run 'make sign' first."; exit 1; \
	fi
	@mkdir -p "$(BUILD_DIR)"
	@rm -f "$(NOTARY_ZIP)"
	@ditto -c -k --keepParent "$(APP)" "$(NOTARY_ZIP)"
	@$(MAKE) --no-print-directory notary-submit SUBMIT_PATH="$(NOTARY_ZIP)"
	@echo "==> Stapling ticket to $(APP)"
	@xcrun stapler staple "$(APP)"
	@xcrun stapler validate "$(APP)"

.PHONY: notarize-dmg
notarize-dmg: ## Submit the .dmg to Apple, wait, then staple the ticket
	$(call require_notary)
	@if [ ! -f "$(DMG)" ]; then echo "error: $(DMG) not found - run 'make dmg' first."; exit 1; fi
	@$(MAKE) --no-print-directory notary-submit SUBMIT_PATH="$(DMG)"
	@echo "==> Stapling ticket to $(DMG)"
	@xcrun stapler staple "$(DMG)"
	@xcrun stapler validate "$(DMG)"

# Internal: submit one artifact and fail loudly (with Apple's log) if rejected.
.PHONY: notary-submit
notary-submit:
	@echo "==> Submitting $(SUBMIT_PATH) to the Apple notary service (this takes a few minutes)"
	@mkdir -p "$(BUILD_DIR)"
	@set -eo pipefail; \
	 json="$(BUILD_DIR)/notarize.json"; \
	 if ! xcrun notarytool submit "$(SUBMIT_PATH)" $(NOTARY_AUTH) --wait --output-format json > "$$json"; then \
		echo "error: notarytool submit failed:"; cat "$$json"; exit 1; \
	 fi; \
	 id=$$(plutil -extract id raw -o - -- "$$json"); \
	 status=$$(plutil -extract status raw -o - -- "$$json"); \
	 echo "    submission $$id: $$status"; \
	 if [ "$$status" != "Accepted" ]; then \
		echo "==> Notarization log:"; \
		xcrun notarytool log "$$id" $(NOTARY_AUTH) || true; \
		exit 1; \
	 fi

# ------------------------------------------------------------------- dmg ---

.PHONY: dmg
dmg: ## Build a distributable .dmg from the signed, stapled app
	$(call require_app)
	@if ! codesign --verify --strict "$(APP)" >/dev/null 2>&1; then \
		echo "warning: $(APP) is not validly signed; this DMG is for local testing only."; \
	fi
	@if ! xcrun stapler validate "$(APP)" >/dev/null 2>&1; then \
		echo "warning: $(APP) has no stapled ticket; run 'make notarize' before shipping."; \
	fi
	@rm -rf "$(STAGE_DIR)"
	@mkdir -p "$(STAGE_DIR)" "$(ARTIFACTS_DIR)"
	@ditto "$(APP)" "$(STAGE_DIR)/$(APP_NAME).app"
	@rm -f "$(DMG)"
	@set -eo pipefail; \
	 tool="$(DMG_TOOL)"; \
	 if [ "$$tool" = auto ]; then \
		if command -v create-dmg >/dev/null 2>&1; then tool=create-dmg; else tool=hdiutil; fi; \
	 fi; \
	 echo "==> Building $(DMG) with $$tool"; \
	 if [ "$$tool" = create-dmg ]; then \
		rc=0; \
		create-dmg \
			--volname "$(VOLNAME)" \
			--window-pos 200 120 --window-size 640 400 \
			--icon-size 128 \
			--icon "$(APP_NAME).app" 160 200 \
			--app-drop-link 480 200 \
			--hide-extension "$(APP_NAME).app" \
			--no-internet-enable \
			"$(DMG)" "$(STAGE_DIR)" || rc=$$?; \
		if [ ! -f "$(DMG)" ]; then echo "error: create-dmg failed (exit $$rc)"; exit 1; fi; \
	 else \
		ln -s /Applications "$(STAGE_DIR)/Applications"; \
		hdiutil create -volname "$(VOLNAME)" -srcfolder "$(STAGE_DIR)" \
			-fs HFS+ -format UDZO -ov "$(DMG)"; \
	 fi
	@if [ -n "$(strip $(SIGN_IDENTITY))" ]; then \
		echo "==> Signing $(DMG)"; \
		codesign --force --timestamp --sign "$(SIGN_IDENTITY)" $(KEYCHAIN_FLAG) "$(DMG)"; \
	 else \
		echo "warning: SIGN_IDENTITY not set; the DMG is unsigned."; \
	 fi
	@echo "==> $(DMG) ($$(du -h "$(DMG)" | cut -f1))"

.PHONY: zip
zip: ## Package the signed, stapled .app as a .zip for direct download
	$(call require_app)
	@mkdir -p "$(ARTIFACTS_DIR)"
	@rm -f "$(ZIP)"
	@ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	@echo "==> $(ZIP)"

# --------------------------------------------------------------- release ---

.PHONY: release
release: ## Full pipeline: build, sign, notarize, dmg, notarize dmg, verify
	@$(MAKE) --no-print-directory clean-artifacts
	@$(MAKE) --no-print-directory build
	@$(MAKE) --no-print-directory sign
	@$(MAKE) --no-print-directory notarize
	@$(MAKE) --no-print-directory dmg
	@$(MAKE) --no-print-directory notarize-dmg
	@$(MAKE) --no-print-directory verify
	@echo
	@echo "==> Release ready: $(DMG)"

.PHONY: verify
verify: ## Check signature, notarization ticket and Gatekeeper acceptance
	$(call require_app)
	@echo "==> codesign"
	@codesign --verify --deep --strict --verbose=2 "$(APP)"
	@codesign --display --verbose=2 "$(APP)" 2>&1 | grep -E 'Authority|TeamIdentifier|flags|Timestamp' | sed 's/^/    /'
	@echo "==> Gatekeeper (app)"
	@spctl --assess --type exec --verbose=4 "$(APP)"
	@echo "==> Stapled ticket (app)"
	@xcrun stapler validate "$(APP)"
	@if [ -f "$(DMG)" ]; then \
		echo "==> Gatekeeper (dmg)"; \
		spctl --assess --type open --context context:primary-signature --verbose=4 "$(DMG)"; \
		echo "==> Stapled ticket (dmg)"; \
		xcrun stapler validate "$(DMG)"; \
	 fi

# ---------------------------------------------------------------- signing setup ---

.PHONY: keychain-import
keychain-import: ## Import CERT_P12 into a temporary keychain (for CI machines)
	$(call require_var,CERT_P12)
	$(call require_var,CERT_P12_PASSWORD)
	@set -eo pipefail; \
	 if [ ! -f "$(CERT_P12)" ]; then echo "error: CERT_P12 not found: $(CERT_P12)"; exit 1; fi; \
	 security create-keychain -p "$(KEYCHAIN_PASSWORD)" "$(KEYCHAIN_NAME)" 2>/dev/null || true; \
	 security set-keychain-settings -lut 21600 "$(KEYCHAIN_NAME)"; \
	 security unlock-keychain -p "$(KEYCHAIN_PASSWORD)" "$(KEYCHAIN_NAME)"; \
	 security import "$(CERT_P12)" -k "$(KEYCHAIN_NAME)" -P "$(CERT_P12_PASSWORD)" \
		-f pkcs12 -T /usr/bin/codesign -T /usr/bin/security; \
	 security set-key-partition-list -S apple-tool:,apple:,codesign: \
		-s -k "$(KEYCHAIN_PASSWORD)" "$(KEYCHAIN_NAME)" >/dev/null; \
	 others=$$(security list-keychains -d user | tr -d '" ' | grep -v "$(KEYCHAIN_NAME)" || true); \
	 security list-keychains -d user -s "$(KEYCHAIN_NAME)" $$others; \
	 echo "==> Imported into $(KEYCHAIN_NAME). Available identities:"; \
	 security find-identity -v -p codesigning "$(KEYCHAIN_NAME)"

.PHONY: keychain-remove
keychain-remove: ## Delete the temporary build keychain
	@security delete-keychain "$(KEYCHAIN_NAME)" 2>/dev/null || true
	@echo "==> Removed $(KEYCHAIN_NAME) (if it existed)."

.PHONY: identities
identities: ## List code signing identities visible to this machine
	@security find-identity -v -p codesigning

.PHONY: doctor
doctor: ## Check toolchain and secrets configuration
	@echo "MacQ $(VERSION) ($(BUILD_NUMBER))"
	@echo
	@echo "Tools"
	@for t in xcodebuild codesign xcrun ditto hdiutil security plutil; do \
		if command -v $$t >/dev/null 2>&1; then echo "  ok       $$t"; else echo "  MISSING  $$t"; fi; \
	 done
	@for t in notarytool stapler; do \
		if xcrun --find $$t >/dev/null 2>&1; then echo "  ok       $$t"; else echo "  MISSING  $$t (needs Xcode 13+)"; fi; \
	 done
	@if command -v create-dmg >/dev/null 2>&1; then \
		echo "  ok       create-dmg (styled DMG)"; \
	 else \
		echo "  -        create-dmg not installed, falling back to hdiutil (brew install create-dmg)"; \
	 fi
	@echo
	@echo "Configuration"
	@if [ -f "$(SECRETS_DIR)/config.mk" ]; then \
		echo "  ok       $(SECRETS_DIR)/config.mk"; \
	 else \
		echo "  MISSING  $(SECRETS_DIR)/config.mk (cp $(SECRETS_DIR)/config.mk.example $(SECRETS_DIR)/config.mk)"; \
	 fi
	@if [ -z "$(strip $(SIGN_IDENTITY))" ]; then \
		echo "  MISSING  SIGN_IDENTITY"; \
	 elif security find-identity -v -p codesigning | grep -qF "$(SIGN_IDENTITY)"; then \
		echo "  ok       SIGN_IDENTITY: $(SIGN_IDENTITY)"; \
	 else \
		echo "  MISSING  SIGN_IDENTITY set to '$(SIGN_IDENTITY)' but no such identity in the keychain"; \
		echo "           (see 'make identities', or 'make keychain-import' with CERT_P12 set)"; \
	 fi
	@if [ -z '$(strip $(NOTARY_AUTH))' ]; then \
		echo "  MISSING  notary credentials"; \
	 else \
		echo "  ok       notary credentials: $(NOTARY_AUTH_DESC)"; \
	 fi
	@if [ -n "$(strip $(ENTITLEMENTS))" ]; then \
		if [ -f "$(ENTITLEMENTS)" ]; then echo "  ok       entitlements: $(ENTITLEMENTS)"; \
		else echo "  MISSING  entitlements file: $(ENTITLEMENTS)"; fi; \
	 else \
		echo "  -        no entitlements file (fine: MacQ needs none)"; \
	 fi
	@if [ -n "$(strip $(PROVISIONING_PROFILE))" ]; then \
		if [ -f "$(PROVISIONING_PROFILE)" ]; then echo "  ok       provisioning profile: $(PROVISIONING_PROFILE)"; \
		else echo "  MISSING  provisioning profile: $(PROVISIONING_PROFILE)"; fi; \
	 else \
		echo "  -        no provisioning profile (fine: Developer ID apps need one only for"; \
		echo "           entitlements like iCloud, push or app groups)"; \
	 fi

# ----------------------------------------------------------------- misc ---

.PHONY: version
version: ## Print the version and build number the next build will use
	@echo "$(APP_NAME) $(VERSION) ($(BUILD_NUMBER))"

.PHONY: run
run: ## Launch the built app from artifacts/
	$(call require_app)
	@open "$(APP)"

.PHONY: clean-artifacts
clean-artifacts: ## Remove artifacts/ only, keeping build/ intermediates
	@rm -rf "$(ARTIFACTS_DIR)"

.PHONY: clean
clean: ## Remove build/ intermediates and artifacts/
	@rm -rf "$(BUILD_DIR)" "$(ARTIFACTS_DIR)"
	@echo "==> Cleaned $(BUILD_DIR)/ and $(ARTIFACTS_DIR)/"

.PHONY: distclean
distclean: clean keychain-remove ## Clean everything, including the temp keychain

.PHONY: help
help: ## Show this help
	@echo "MacQ $(VERSION) - build, sign, notarize and package"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'
	@echo
	@echo "Secrets and credentials: $(SECRETS_DIR)/README.md"
