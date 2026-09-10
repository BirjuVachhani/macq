# MacQ release pipeline
#
#   make dmg            build a release-ready .dmg: build, sign, notarize the
#                       app, package it, notarize the .dmg and verify the result
#   make release        make dmg, generate the Sparkle appcast, and publish
#                       both to the Cloudflare R2 bucket
#
# The individual steps, if you need to run one on its own:
#
#   make build          compile a universal Release .app (unsigned)
#   make sign           codesign it with Developer ID + hardened runtime
#   make notarize       submit the .app to Apple, wait for the ticket, staple it
#   make dmg-package    wrap the app already in artifacts/, without rebuilding
#   make notarize-dmg   notarize and staple the .dmg itself
#   make appcast        sign the .dmg and write artifacts/appcast.xml
#   make publish        upload an already-built release .dmg and appcast to R2
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
DMG_NAME   := $(APP_NAME)-$(VERSION).dmg
DMG        := $(ARTIFACTS_DIR)/$(DMG_NAME)
ZIP        := $(ARTIFACTS_DIR)/$(APP_NAME)-$(VERSION).zip
NOTARY_ZIP := $(BUILD_DIR)/$(APP_NAME)-notarize.zip
VOLNAME    := $(APP_NAME) $(VERSION)

INFO_PLIST   := app/$(APP_NAME)/Info.plist
CHANGELOG    := CHANGELOG.md
APPCAST_NAME := appcast.xml
APPCAST      := $(ARTIFACTS_DIR)/$(APPCAST_NAME)
APPCAST_TOOL        := scripts/appcast.py
SPARKLE_KEY_CHECKER := scripts/sparkle_public_key.swift

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

# ------------------------------------------------------------ publishing ---

# Cloudflare R2, reached over its S3-compatible API. R2_FOLDER is optional; an
# empty value puts the objects at the root of the bucket.
R2_ENDPOINT := https://$(strip $(R2_ACCOUNT_ID)).r2.cloudflarestorage.com
R2_FOLDER_CLEAN := $(patsubst /%,%,$(patsubst %/,%,$(strip $(R2_FOLDER))))
R2_PREFIX   := $(if $(R2_FOLDER_CLEAN),$(R2_FOLDER_CLEAN)/,)

# config.mk.example ships these as "change-me", so a half-filled config counts
# as unconfigured and fails before the build rather than as a 403 from
# Cloudflare after it. This collects the *names* of the unusable settings and
# never their values, so no credential can reach a terminal or a process list.
r2_unset   = $(if $(filter-out change-me,$(strip $($(1)))),,$(1))
R2_MISSING := $(strip $(call r2_unset,R2_ACCOUNT_ID) $(call r2_unset,R2_ACCESS_KEY_ID) \
                      $(call r2_unset,R2_SECRET_ACCESS_KEY) $(call r2_unset,R2_BUCKET))

# The upload reads the key and the secret out of the environment rather than
# out of curl's argument list, where `ps` would show them to anyone on the
# machine. They are exported only for r2-put, rather than inherited by every
# build and notarization process this Makefile starts.

# --------------------------------------------------------------- sparkle ---

# In-app updates. The app polls SUFeedURL from Info.plist and installs nothing
# that is not signed by the EdDSA key whose public half sits next to it in
# SUPublicEDKey; the private half lives in the login keychain, put there by
# Sparkle's generate_keys, and is what sign_update reaches for.
#
# Both the appcast and the DMG are served from the same directory as the feed,
# so the public URLs are derived from SUFeedURL rather than configured twice.
# Overriding PUBLIC_BASE_URL is for testing against a scratch bucket.
FEED_URL        := $(shell plutil -extract SUFeedURL raw -o - -- $(INFO_PLIST) 2>/dev/null)
PUBLIC_BASE_URL ?= $(patsubst %/,%,$(dir $(FEED_URL)))

# Sparkle offers the release with the highest sparkle:version, which is
# CFBundleVersion, so this has to move between releases even when only the
# marketing version changes. `./set_version.sh <version> ++` does both.
MIN_SYSTEM_VERSION ?= $(shell sed -n 's/^[[:space:]]*MACOSX_DEPLOYMENT_TARGET = \(.*\);/\1/p' $(XCODE_PROJECT)/project.pbxproj | head -1 | tr -d '"')

# sign_update ships in Sparkle's release tarball rather than in the Swift
# package, so `make sparkle-tools` fetches it on demand. Pinned to the version
# the app links against, and cached in build/ (which `make clean` empties, at
# the cost of one download).
SPARKLE_VERSION   ?= 2.9.6
SPARKLE_TOOLS_DIR := $(BUILD_DIR)/sparkle-tools
SIGN_UPDATE       ?= $(SPARKLE_TOOLS_DIR)/bin/sign_update
GENERATE_KEYS     ?= $(SPARKLE_TOOLS_DIR)/bin/generate_keys

# Which private key sign_update reaches for. The keychain stores keys under a
# named account, and left to itself sign_update takes the default one - which on
# a Mac that has ever shipped another Sparkle app is somebody else's key. Signing
# with it produces a DMG that every installed copy of MacQ refuses to install,
# and nothing says so until a user tries to update, so the account is named here
# rather than defaulted.
#
# The exported copy in secrets/ takes precedence when it exists, so a release is
# reproducible on a machine whose keychain is empty and CI can write the key to
# that path from a repository secret. Either way `make doctor` checks the key in
# use against the SUPublicEDKey the app actually trusts.
SPARKLE_ACCOUNT  ?= macq
SPARKLE_KEY_FILE ?= $(SECRETS_DIR)/sparkle_ed25519_private.key
SPARKLE_KEY_ARGS := $(if $(wildcard $(SPARKLE_KEY_FILE)),--ed-key-file "$(SPARKLE_KEY_FILE)",--account "$(SPARKLE_ACCOUNT)")

# ------------------------------------------------------------ guard rails ---

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

define require_r2
@if [ -n "$(R2_MISSING)" ]; then \
	echo "error: Cloudflare R2 upload is not configured."; \
	echo "       Unset or still 'change-me': $(R2_MISSING)"; \
	echo "       Set them in $(SECRETS_DIR)/config.mk (see $(SECRETS_DIR)/config.mk.example),"; \
	echo "       or run 'make dmg' to build the DMG without publishing it."; \
	exit 1; \
fi
endef

# ----------------------------------------------------------------- build ---

# The macOS 26 media-key indicator uses NSGlassEffectView, which exists only in
# the macOS 26 SDK. `#available(macOS 26.0, *)` gates it at *runtime*, so the app
# still runs on macOS 14, but compiling that call at all needs the newer SDK.
# Building with an older Xcode fails a minute in with "cannot find
# NSGlassEffectView in scope", which does not say what is actually wrong, so the
# SDK is checked up front instead.
MIN_SDK_MAJOR := 26

.PHONY: check-sdk
check-sdk:
	@sdk=$$(xcrun --sdk macosx --show-sdk-version 2>/dev/null); \
	 if [ -z "$$sdk" ]; then \
	   echo "error: no macOS SDK found. Install Xcode and run xcode-select." >&2; \
	   exit 1; \
	 fi; \
	 if [ "$${sdk%%.*}" -lt $(MIN_SDK_MAJOR) ]; then \
	   echo "error: macOS SDK $$sdk is too old; MacQ needs $(MIN_SDK_MAJOR) or newer." >&2; \
	   echo "       Xcode in use: $$(xcode-select -p)" >&2; \
	   echo "       Point at a newer one, e.g.:" >&2; \
	   echo "         sudo xcode-select -s /Applications/Xcode_26.app" >&2; \
	   exit 1; \
	 fi

.PHONY: build
build: check-sdk ## Compile a universal Release .app (unsigned) into artifacts/
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
# Signed in three passes, innermost first, because codesign seals a bundle over
# its contents and will not re-seal one whose nested code changed afterwards.
#
# The middle pass is for helper executables that sit loose inside a framework
# rather than in a bundle of their own: Sparkle ships Autoupdate exactly that
# way. It has no extension for the bundle pass to match on, and it arrives from
# the Swift package ad-hoc signed rather than Developer ID signed, so without
# that pass the app notarizes as "not signed with a valid Developer ID". Nested
# bundles are matched on the path *below* Frameworks/, since matching the whole
# path would see the enclosing MacQ.app and skip everything.
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
	 root="$(APP)/Contents/Frameworks"; \
	 find "$$root" -type f -perm -u+x ! -name '*.dylib' ! -name '*.so' -print0 2>/dev/null | \
	 while IFS= read -r -d '' f; do \
		case "$${f#$$root/}" in *.app/*|*.xpc/*|*.appex/*|*.bundle/*) continue;; esac; \
		case "$$(file -b "$$f")" in *Mach-O*) ;; *) continue;; esac; \
		echo "    nested: $$f"; codesign $(CODESIGN_FLAGS) "$$f"; \
	 done
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
	@if [ ! -f "$(DMG)" ]; then echo "error: $(DMG) not found - run 'make dmg-package' first."; exit 1; fi
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

# `make dmg` produces a DMG that is ready to ship: the app is signed, notarized
# and stapled, the DMG wrapping it is signed and notarized in turn, and the
# whole thing is verified against Gatekeeper before the target succeeds.
#
# Packaging on its own is `dmg-package`, which wraps whatever app is already in
# artifacts/ and only warns when that app is unsigned - use `make build` then
# `make dmg-package` for a throwaway DMG to test locally.
.PHONY: dmg
dmg: ## Build, sign, notarize and package a release-ready .dmg
	@$(MAKE) --no-print-directory release-preflight
	@$(MAKE) --no-print-directory clean-artifacts
	@$(MAKE) --no-print-directory build
	@$(MAKE) --no-print-directory sign
	@$(MAKE) --no-print-directory notarize
	@$(MAKE) --no-print-directory dmg-package
	@$(MAKE) --no-print-directory notarize-dmg
	@$(MAKE) --no-print-directory verify
	@echo
	@echo "==> Release ready: $(DMG)"

# Internal: fail on missing credentials before the build, not after it. Without
# this, an unset SIGN_IDENTITY or notary credential surfaces at `sign`, several
# minutes into a compile whose output then has to be thrown away.
.PHONY: release-preflight
release-preflight: check-sdk
	$(call require_var,SIGN_IDENTITY)
	$(call require_notary)

.PHONY: dmg-package
dmg-package: ## Package the app already in artifacts/ into a .dmg, without rebuilding
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

# --------------------------------------------------------------- appcast ---

.PHONY: sparkle-tools
sparkle-tools: ## Fetch Sparkle's CLI tools (sign_update) into build/
	@set -eo pipefail; \
	 if [ -x "$(SIGN_UPDATE)" ]; then exit 0; fi; \
	 url="https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz"; \
	 echo "==> Fetching Sparkle $(SPARKLE_VERSION) tools"; \
	 tmp=$$(mktemp -d); \
	 trap 'rm -rf "$$tmp"' EXIT; \
	 if ! curl --fail --silent --show-error --location "$$url" -o "$$tmp/sparkle.tar.xz"; then \
		echo "error: could not download $$url"; exit 1; \
	 fi; \
	 mkdir -p "$(SPARKLE_TOOLS_DIR)"; \
	 tar -xJf "$$tmp/sparkle.tar.xz" -C "$(SPARKLE_TOOLS_DIR)" ./bin; \
	 if [ ! -x "$(SIGN_UPDATE)" ]; then \
		echo "error: $(SIGN_UPDATE) is missing from the Sparkle tarball."; exit 1; \
	 fi; \
	 echo "    $(SIGN_UPDATE)"

# Writes artifacts/appcast.xml: the release notes for $(VERSION) out of
# CHANGELOG.md, plus the DMG's length and EdDSA signature. The feed currently
# published is merged in first, so earlier releases stay in it. Only a real 404
# starts a new feed; a network or server failure aborts rather than overwriting
# a live feed without its history or build-number guard.
.PHONY: appcast
appcast: sparkle-tools ## Sign the .dmg and write artifacts/appcast.xml
	@if [ ! -f "$(DMG)" ]; then \
		echo "error: $(DMG) not found - run 'make dmg' first."; exit 1; \
	fi
	@if [ ! -f "$(CHANGELOG)" ]; then \
		echo "error: $(CHANGELOG) not found; the appcast takes its release notes from it."; exit 1; \
	fi
	@if [ -z "$(strip $(FEED_URL))" ]; then \
		echo "error: no SUFeedURL in $(INFO_PLIST), so the download URL cannot be derived."; exit 1; \
	fi
	@echo "==> Building the appcast for $(VERSION) ($(BUILD_NUMBER))"
	@set -eo pipefail; \
	 mkdir -p "$(BUILD_DIR)"; \
	 signed=$$("$(SIGN_UPDATE)" $(SPARKLE_KEY_ARGS) "$(DMG)"); \
	 signature=$$(printf '%s' "$$signed" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p'); \
	 length=$$(printf '%s' "$$signed" | sed -n 's/.*length="\([^"]*\)".*/\1/p'); \
	 if [ -z "$$signature" ] || [ -z "$$length" ]; then \
		echo "error: sign_update did not return a signature:"; echo "    $$signed"; \
		echo "       Expected $(SPARKLE_KEY_FILE), or a key in the keychain"; \
		echo "       under the '$(SPARKLE_ACCOUNT)' account. See 'make doctor'."; \
		exit 1; \
	 fi; \
	 previous="$(BUILD_DIR)/appcast-published.xml"; \
	 rm -f "$$previous"; merge=""; \
	 code=$$(curl --silent --show-error --location --max-time 30 \
		--header 'Cache-Control: no-cache' \
		--output "$$previous" --write-out '%{http_code}' \
		"$(PUBLIC_BASE_URL)/$(APPCAST_NAME)?release-check=$$(date +%s)") || code=000; \
	 case "$$code" in \
		200) merge="--existing $$previous"; \
			echo "    merging into the feed already published" ;; \
		404) rm -f "$$previous"; \
			echo "    no feed published yet, starting one" ;; \
		*) rm -f "$$previous"; \
			echo "error: could not read the published appcast (HTTP $$code)."; \
			echo "       Refusing to replace it without its release history."; \
			exit 1 ;; \
	 esac; \
	 python3 "$(APPCAST_TOOL)" \
		--version "$(VERSION)" \
		--build "$(BUILD_NUMBER)" \
		--url "$(PUBLIC_BASE_URL)/$(DMG_NAME)" \
		--length "$$length" \
		--signature "$$signature" \
		--changelog "$(CHANGELOG)" \
		--feed-url "$(FEED_URL)" \
		--min-system-version "$(MIN_SYSTEM_VERSION)" \
		--title "$(APP_NAME)" \
		--output "$(APPCAST)" \
		$$merge

# --------------------------------------------------------------- publish ---

# Uploads over R2's S3-compatible API, with curl signing the request itself
# (SigV4), so publishing needs no aws CLI, no wrangler and no rclone - just the
# curl that ships with macOS.
#
# The checksum sidecar is written with a bare filename inside it, so that
# `shasum -c MacQ-x.y.z.dmg.sha256` works next to the downloaded DMG. This is
# the same pair the release workflow attaches to a GitHub release.
#
# The appcast goes up last, on purpose. It is the file the app polls, so
# publishing it before the DMG it points at would offer every running copy of
# MacQ an update that 404s for as long as the upload takes.
.PHONY: publish
publish: ## Upload the release .dmg, its checksum and the appcast to R2
	$(call require_r2)
	@if [ ! -f "$(DMG)" ]; then \
		echo "error: $(DMG) not found - run 'make dmg' first."; exit 1; \
	fi
	@if ! xcrun stapler validate "$(DMG)" >/dev/null 2>&1; then \
		echo "error: $(DMG) carries no stapled notarization ticket, so it is not"; \
		echo "       fit to publish - run 'make dmg' to build a release DMG."; \
		exit 1; \
	fi
	@$(MAKE) --no-print-directory appcast
	@echo "==> Publishing to r2://$(R2_BUCKET)/$(R2_PREFIX)"
	@( cd "$(ARTIFACTS_DIR)" && shasum -a 256 "$(DMG_NAME)" > "$(DMG_NAME).sha256" )
	@$(MAKE) --no-print-directory r2-put SRC="$(DMG)" \
		KEY="$(R2_PREFIX)$(DMG_NAME)" TYPE=application/x-apple-diskimage
	@$(MAKE) --no-print-directory r2-put SRC="$(DMG).sha256" \
		KEY="$(R2_PREFIX)$(DMG_NAME).sha256" TYPE=text/plain
	@$(MAKE) --no-print-directory r2-put SRC="$(APPCAST)" \
		KEY="$(R2_PREFIX)$(APPCAST_NAME)" TYPE=application/xml
	@echo "==> Published $(DMG_NAME) and $(APPCAST_NAME) to r2://$(R2_BUCKET)/$(R2_PREFIX)"
	@echo "    the update feed is now $(FEED_URL)"

# Internal: PUT one file into the bucket. SRC is the local path, KEY the object
# key within the bucket, TYPE the Content-Type to store it under.
.PHONY: r2-put
r2-put: export R2_ACCESS_KEY_ID := $(R2_ACCESS_KEY_ID)
r2-put: export R2_SECRET_ACCESS_KEY := $(R2_SECRET_ACCESS_KEY)
r2-put:
	@echo "    $(notdir $(SRC)) ($$(du -h "$(SRC)" | cut -f1 | tr -d ' ')) -> $(KEY)"
	@set -eo pipefail; \
	 mkdir -p "$(BUILD_DIR)"; \
	 body="$(BUILD_DIR)/r2-response.xml"; \
	 rm -f "$$body"; \
	 if ! printf 'user = %s:%s\n' "$$R2_ACCESS_KEY_ID" "$$R2_SECRET_ACCESS_KEY" | \
		curl --config - \
			--aws-sigv4 'aws:amz:auto:s3' \
			--upload-file "$(SRC)" \
			--header 'Content-Type: $(TYPE)' \
			--retry 3 --retry-connrefused \
			--silent --show-error --fail-with-body \
			--output "$$body" \
			"$(R2_ENDPOINT)/$(R2_BUCKET)/$(KEY)"; then \
		echo "error: uploading $(KEY) to R2 failed."; \
		if [ -s "$$body" ]; then sed 's/^/    /' "$$body"; echo; fi; \
		exit 1; \
	 fi

# Internal: verify the separate credentials needed to announce the DMG through
# Sparkle. Kept out of release-preflight because `make dmg` deliberately stops
# before publishing and must not need an R2 token or an update-signing key.
.PHONY: publish-preflight
publish-preflight: sparkle-tools
	$(call require_r2)
	@set -eo pipefail; \
	 probe=$$(mktemp); \
	 trap 'rm -f "$$probe"' EXIT; \
	 printf 'MacQ Sparkle key preflight' > "$$probe"; \
	 if ! signed=$$("$(SIGN_UPDATE)" $(SPARKLE_KEY_ARGS) "$$probe" 2>&1); then \
		echo "error: the Sparkle EdDSA private key is unavailable."; \
		echo "       Expected $(SPARKLE_KEY_FILE), or keychain account '$(SPARKLE_ACCOUNT)'."; \
		exit 1; \
	 fi; \
	 case "$$signed" in *'sparkle:edSignature="'*) ;; \
		*) echo "error: sign_update did not return a Sparkle signature."; exit 1;; \
	 esac; \
	 trusted=$$(plutil -extract SUPublicEDKey raw -o - -- "$(INFO_PLIST)" 2>/dev/null); \
	 if [ -n "$(findstring --ed-key-file,$(SPARKLE_KEY_ARGS))" ]; then \
		actual=$$("$(SPARKLE_KEY_CHECKER)" "$(SPARKLE_KEY_FILE)"); \
	 else \
		actual=$$("$(GENERATE_KEYS)" -p --account "$(SPARKLE_ACCOUNT)" 2>/dev/null); \
	 fi; \
	 if [ -z "$$trusted" ] || [ "$$actual" != "$$trusted" ]; then \
		echo "error: the Sparkle signing key does not match SUPublicEDKey in $(INFO_PLIST)."; \
		echo "       Updates signed with it would be rejected by every installed copy."; \
		exit 1; \
	 fi

# --------------------------------------------------------------- release ---

# The full ship: everything `make dmg` does, then the appcast and the upload.
# The R2 settings and the changelog entry are checked first, so a missing
# credential or a release note nobody wrote costs a second rather than a build
# and two notarization round trips.
.PHONY: release
release: ## Build a release-ready .dmg, then publish it and the appcast to R2
	@python3 "$(APPCAST_TOOL)" --version "$(VERSION)" \
		--changelog "$(CHANGELOG)" --check-changelog
	@$(MAKE) --no-print-directory publish-preflight
	@$(MAKE) --no-print-directory dmg
	@$(MAKE) --no-print-directory publish

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
	@for t in xcodebuild codesign xcrun ditto hdiutil security plutil shasum; do \
		if command -v $$t >/dev/null 2>&1; then echo "  ok       $$t"; else echo "  MISSING  $$t"; fi; \
	 done
	@for t in notarytool stapler; do \
		if xcrun --find $$t >/dev/null 2>&1; then echo "  ok       $$t"; else echo "  MISSING  $$t (needs Xcode 13+)"; fi; \
	 done
	@sdk=$$(xcrun --sdk macosx --show-sdk-version 2>/dev/null); \
	 if [ -z "$$sdk" ]; then \
		echo "  MISSING  macOS SDK"; \
	 elif [ "$${sdk%%.*}" -lt $(MIN_SDK_MAJOR) ]; then \
		echo "  TOO OLD  macOS SDK $$sdk (needs $(MIN_SDK_MAJOR)+; $$(xcode-select -p))"; \
	 else \
		echo "  ok       macOS SDK $$sdk"; \
	 fi
	@if command -v create-dmg >/dev/null 2>&1; then \
		echo "  ok       create-dmg (styled DMG)"; \
	 else \
		echo "  -        create-dmg not installed, falling back to hdiutil (brew install create-dmg)"; \
	 fi
	@if curl --help all 2>/dev/null | grep -q -- '--aws-sigv4'; then \
		echo "  ok       curl $$(curl --version | head -1 | cut -d' ' -f2) with --aws-sigv4 (R2 upload)"; \
	 else \
		echo "  MISSING  curl with --aws-sigv4 (needs 7.75+; 'make publish' cannot sign its uploads)"; \
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
	@echo
	@echo "Publishing (Cloudflare R2)"
	@if [ -n "$(R2_MISSING)" ]; then \
		echo "  MISSING  $(R2_MISSING)"; \
		echo "           Only 'make release' and 'make publish' need these; 'make dmg' does not."; \
	 else \
		echo "  ok       destination: r2://$(R2_BUCKET)/$(R2_PREFIX)"; \
	 fi
	@echo
	@echo "In-app updates (Sparkle)"
	@if [ -z "$(strip $(FEED_URL))" ]; then \
		echo "  MISSING  no SUFeedURL in $(INFO_PLIST)"; \
	 else \
		echo "  ok       feed: $(FEED_URL)"; \
		echo "  ok       uploads land at: $(PUBLIC_BASE_URL)/"; \
	 fi
	@if [ -x "$(SIGN_UPDATE)" ]; then \
		echo "  ok       sign_update: $(SIGN_UPDATE)"; \
	 else \
		echo "  -        sign_update not fetched yet ('make sparkle-tools', or any 'make appcast')"; \
	 fi
	@if [ -x "$(SIGN_UPDATE)" ]; then \
		probe=$$(mktemp); printf 'probe' > "$$probe"; \
		if "$(SIGN_UPDATE)" $(SPARKLE_KEY_ARGS) "$$probe" >/dev/null 2>&1; then \
			if [ -n "$(findstring --ed-key-file,$(SPARKLE_KEY_ARGS))" ]; then \
				echo "  ok       signing key: $(SPARKLE_KEY_FILE)"; \
			else \
				echo "  ok       signing key: keychain account '$(SPARKLE_ACCOUNT)'"; \
			fi; \
		else \
			echo "  MISSING  no Sparkle EdDSA private key; 'make appcast' cannot sign the DMG"; \
			echo "           looked for $(SPARKLE_KEY_FILE) and keychain account '$(SPARKLE_ACCOUNT)'"; \
			echo "           (without it no build can ever update an installed copy)"; \
		fi; \
		rm -f "$$probe"; \
	 fi
	@trusted=$$(plutil -extract SUPublicEDKey raw -o - -- "$(INFO_PLIST)" 2>/dev/null); \
	 if [ -z "$$trusted" ]; then \
		echo "  MISSING  no SUPublicEDKey in $(INFO_PLIST); the app trusts no update key"; \
	 elif [ ! -x "$(GENERATE_KEYS)" ]; then \
		echo "  -        public key: $$trusted (run 'make sparkle-tools' to check the pair)"; \
	 elif [ -n "$(findstring --ed-key-file,$(SPARKLE_KEY_ARGS))" ]; then \
		if ! actual=$$("$(SPARKLE_KEY_CHECKER)" "$(SPARKLE_KEY_FILE)" 2>/dev/null); then \
			echo "  MISSING  could not derive a public key from $(SPARKLE_KEY_FILE)"; \
		elif [ "$$actual" = "$$trusted" ]; then \
			echo "  ok       signing key matches SUPublicEDKey in $(INFO_PLIST)"; \
		else \
			echo "  MISMATCH $(SPARKLE_KEY_FILE) does not match SUPublicEDKey"; \
		fi; \
	 elif ! actual=$$("$(GENERATE_KEYS)" -p --account "$(SPARKLE_ACCOUNT)" 2>/dev/null); then \
		echo "  MISSING  no '$(SPARKLE_ACCOUNT)' key in this keychain to compare"; \
	 elif [ "$$actual" = "$$trusted" ]; then \
		echo "  ok       signing key matches SUPublicEDKey in $(INFO_PLIST)"; \
	 else \
		echo "  MISMATCH the '$(SPARKLE_ACCOUNT)' key signs as $$actual"; \
		echo "           but the app only trusts   $$trusted"; \
		echo "           Updates signed with it would be rejected by every installed copy."; \
	 fi
	@if [ ! -f "$(CHANGELOG)" ]; then \
		echo "  MISSING  $(CHANGELOG), which the appcast takes its release notes from"; \
	 elif grep -qE '^##[[:space:]]+\[?v?$(VERSION)\]?([[:space:]]|$$)' "$(CHANGELOG)"; then \
		echo "  ok       $(CHANGELOG) has a section for $(VERSION)"; \
	 else \
		echo "  MISSING  $(CHANGELOG) has no '## [$(VERSION)]' section for this release"; \
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
