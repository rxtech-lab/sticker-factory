# Entry points for the two halves of the project. Every target shells out to the same script or
# package command CI runs, so `make lint` locally and the lint step in CI cannot drift apart.

IOS_SCRIPTS := StickerGeniOS/scripts

.PHONY: help lint lint-ios lint-node lint-fix build test

help:
	@echo "make lint       — lint both the iOS sources and the server"
	@echo "make lint-ios   — SwiftLint over the iOS app, extensions and packages"
	@echo "make lint-node  — ESLint over the Next.js server"
	@echo "make lint-fix   — apply what both linters can correct, then lint"
	@echo "make build      — build the StickerGeniOS scheme for a device"
	@echo "make test       — run the StickerGeniOS test suites on a simulator"

lint: lint-ios lint-node

lint-ios:
	@$(IOS_SCRIPTS)/ios-lint.sh

lint-node:
	@cd server && bun run lint

lint-fix:
	@$(IOS_SCRIPTS)/ios-lint.sh --fix
	@cd server && bunx eslint . --fix
	@$(MAKE) lint

build:
	@$(IOS_SCRIPTS)/ios-build.sh

test:
	@$(IOS_SCRIPTS)/ios-test.sh
