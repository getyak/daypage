.PHONY: tokens-build tokens-check

# Regenerate web CSS + iOS Swift tokens from design-tokens/tokens.json.
tokens-build:
	node --experimental-strip-types design-tokens/generators/to-css.ts
	node --experimental-strip-types design-tokens/generators/to-swift.ts

# CI guard: regenerate and fail if the working tree is dirty.
tokens-check: tokens-build
	git diff --exit-code -- web/src/app/globals.css DayPage/App/DSTokens.swift
