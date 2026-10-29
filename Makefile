SHELL := /bin/bash

PYTHON ?= python3
PNPM ?= pnpm
SCHEME ?= DayPage
PROJECT ?= DayPageLocal/DayPageLocal.xcodeproj
SIMULATOR_FALLBACK ?= iPhone 16
DERIVED_DATA ?= build/DD

# Reasons are literal audit text, including dollar expressions. Freeze the raw
# input before Make recursively expands environment or command-line variables.
override DEV_IOS_REASON := $(value DEV_IOS_REASON)

# Export the iOS gate inputs only for the two iOS targets. Make passes these
# through the process environment verbatim (spaces and shell metacharacters are
# data), and no recipe line re-interpolates them into a shell command.
check-ios build-ios: export PROJECT := $(PROJECT)
check-ios build-ios: export SCHEME := $(SCHEME)
check-ios build-ios: export DERIVED_DATA := $(DERIVED_DATA)
check-ios build-ios: export PYTHON := $(PYTHON)
check-ios build-ios: export SIMULATOR_FALLBACK := $(SIMULATOR_FALLBACK)
check-ios build-ios: export DEV_IOS_PROFILE := $(DEV_IOS_PROFILE)
check-ios build-ios: export DEV_IOS_REASON := $(DEV_IOS_REASON)
check-ios build-ios: export IOS_ONLY_TESTING := $(IOS_ONLY_TESTING)
check-ios build-ios: export IOS_RESULT_BUNDLE_PATH := $(IOS_RESULT_BUNDLE_PATH)

.PHONY: \
	doctor check check-agent check-scripts check-kit check-web check-android check-mcp check-contracts \
	check-agentry check-localization check-tokens check-ios build-ios \
	ci-secrets simulator-destination tokens-build tokens-check \
	dsh-doctor dsh-config dsh-web

# Developer preflight: repository contracts plus the available local toolchain.
doctor:
	$(PYTHON) scripts/agent/doctor.py --root . --environment

# DeepSeek Harness is an opt-in development host. These targets never run in
# the default merge gate because the runtime probe and UI require local credentials.
dsh-doctor:
	$(PYTHON) scripts/agent/dsh.py doctor --runtime

dsh-config:
	$(PYTHON) scripts/agent/dsh.py dump-config

dsh-web:
	$(PYTHON) scripts/agent/dsh.py web

# Portable, non-Simulator merge gates. Use the scoped targets while iterating.
check: check-agent check-scripts check-kit check-web check-android check-mcp check-contracts check-agentry check-localization check-tokens

check-agent:
	$(PYTHON) scripts/agent/doctor.py --root .
	$(PYTHON) -m unittest discover -s scripts/agent -p 'test_*.py'

check-scripts:
	bash scripts/ci/run_script_tests.sh

check-kit:
	swift test --package-path DayPageKit
	swift test --package-path DayPageCore

check-web:
	$(PNPM) web:lint
	$(PNPM) web:typecheck

check-android:
	cd android && ./gradlew testDebugUnitTest lintDebug assembleDebug

check-mcp:
	$(PNPM) --filter daypage-mcp-server test

check-contracts:
	$(PNPM) contracts:test

check-agentry:
	cd agentry && go test ./...
	cd agentry && go vet ./...
	cd agentry && go build ./...

check-localization:
	bash scripts/check_localization_parity.sh

# Regenerate web CSS + Apple Swift + Android Compose tokens from design-tokens/tokens.json.
tokens-build:
	node --experimental-strip-types design-tokens/generators/to-css.ts
	node --experimental-strip-types design-tokens/generators/to-swift.ts
	node --experimental-strip-types design-tokens/generators/to-kotlin.ts

check-tokens: tokens-check

# CI guard: regenerate and fail if the working tree is dirty.
tokens-check: tokens-build
	git diff --exit-code -- web/src/app/globals.css DayPage/App/DSTokens.swift \
		design-tokens/generated/kotlin/app/daypage/designsystem/DayPageTokens.kt

# Direct CI helpers; ci-secrets always writes a non-sensitive placeholder.
ci-secrets:
	bash scripts/ci/write_placeholder_secrets.sh

simulator-destination:
	@xcrun simctl list devices available --json \
		| $(PYTHON) scripts/ci/select_simulator.py --format destination --fallback-name "$(SIMULATOR_FALLBACK)"

# Local iOS gates. Both route through scripts/ci/ios-local.sh so a macOS host
# with the shared device-session helper serializes against one owner. The
# required inputs are exported above; nothing is interpolated into the recipe.
check-ios:
	@bash scripts/ci/ios-local.sh check

build-ios:
	@bash scripts/ci/ios-local.sh build
