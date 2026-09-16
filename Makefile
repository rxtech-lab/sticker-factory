# Entry points for the two halves of the project. Every target shells out to the same script or
# package command CI runs, so `make lint` locally and the lint step in CI cannot drift apart.

IOS_SCRIPTS := StickerGeniOS/scripts

.PHONY: help lint lint-ios lint-node lint-fix build test test-ui test-appclip test-unit test-tutorial

help:
	@echo "make lint       — lint both the iOS sources and the server"
	@echo "make lint-ios   — SwiftLint over the iOS app, extensions and packages"
	@echo "make lint-node  — ESLint over the Next.js server"
	@echo "make lint-fix   — apply what both linters can correct, then lint"
	@echo "make build      — build the StickerGeniOS scheme for a device"
	@echo "make test       — run the AllTests plan (unit + UI) on a simulator"
	@echo "make test-ui    — run the UITests plan, the suite CI runs on every push"
	@echo "make test-unit  — run the UnitTests plan only"
	@echo "make test-appclip — run the AppClipUITests plan"
	@echo "make test-tutorial — run the TutorialUITests plan (needs the server on :3117)"

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

test-ui:
	@STICKER_FACTORY_TEST_PLAN=UITests $(IOS_SCRIPTS)/ios-test.sh

test-unit:
	@STICKER_FACTORY_TEST_PLAN=UnitTests $(IOS_SCRIPTS)/ios-test.sh

test-appclip:
	@STICKER_FACTORY_SCHEME=StickerAppClip STICKER_FACTORY_TEST_PLAN=AppClipUITests $(IOS_SCRIPTS)/ios-test.sh

# The tutorial suite reads its content over HTTP: start `bun run dev:e2e`-style server on 3117 with
# `cd server && STICKER_FACTORY_TUTORIAL_PREVIEW=true bun x next dev -p 3117` before running this.
test-tutorial:
	@STICKER_FACTORY_TEST_PLAN=TutorialUITests STICKER_FACTORY_PARALLEL=0 $(IOS_SCRIPTS)/ios-test.sh
