# Winky tutorials

The iOS reader is native SwiftUI. It downloads versioned JSON from the public `/api/v1/tutorial/{locale}` endpoint. No tutorial WebView, executable MDX, HTML, JavaScript bridge, account cookies or authorization tokens are used. The browser companion remains available at `/tutorial/{locale}/{chapter}?step={step}`.

## Authoring and publishing

- Edit `server/content/tutorial/{en,zh-CN,zh-HK}/*.mdx` and keep chapter/step IDs stable across languages. The registry is `server/lib/tutorial/catalog.ts`.
- Supported native blocks: paragraphs, inline emphasis/code, headings, lists, `TutorialMedia`, `TutorialCallout` and typed feature actions. The compiler rejects unsupported nodes and executable expressions.
- `bun run tutorial:compile` regenerates `server/lib/tutorial/documents.generated.json`. The normal dev/build commands also compile it. Commit generated content together with MDX so the API and browser stay aligned.
- Content schema version 1 lives in `server/lib/tutorial/document.ts` and `StickerGeniOS/Tutorial/TutorialDocument.swift`. Native validation contains actions and media to the known action vocabulary and configured tutorial origin. Unsupported schema/content shows Retry and Close.
- Content is cached through ordinary HTTP caching. This is not an offline-content promise. Progress is device-local under `winky.tutorial.progress.v1` and is shared across tutorial languages.
- Deploy the server and check all three content endpoints/media paths before releasing iOS entry points. The existing Vercel project is `rxlab/sticker-factory`, with `server` as its root directory.

## Native presentation

Account Help opens the chapter index. Creation, plan, controls, pack creation/detail and export have contextual entries. Each local presenter keeps its unfinished form alive; explicit feature actions run after tutorial dismissal. Unknown-context actions open a selection screen, and never generate, publish or send automatically.

The tutorial sheet disables interactive dismissal. Close is the dismissal control; Try it intentionally transitions to a feature. Finish chapter records completion, announces it for VoiceOver, triggers success haptics, and displays a three-second banner. The same primary button becomes Next chapter, or All chapters at the end of the final chapter. While a step still runs past the fold the primary button reads Scroll down and pages through the rest of the lesson — two thirds of the step's travel per tap, capped at 0.65 of a screen, animated unless Reduce Motion is on — and only becomes the forward action once the step is scrolled to its end. The language menu lists English, 简体中文 and 繁體中文 directly, marks the current choice and preserves chapter/step while fetching the selected translation.

First launch retains Welcome → What’s New. Only the last feature-card page offers Read tutorials, acknowledges its card, and opens tutorials after launch-sheet dismissal. A replayed Welcome includes its final tutorial button. Existing announcement IDs and acknowledgement data are retained; `tutorial-library` is appended. New TipKit education is app-owned and enters shared controls through optional hooks.

## Media provenance and regeneration

`source/{locale}` preserves actual simulator screenshots and short source clips from `TutorialCaptureTests`. They use a mock service, curated demo sticker assets and real app views; there are no fabricated messenger screens. The captures show the app’s preparation and unavailable-messenger states. Source pixels stay unannotated: SwiftUI and CSS add the frame, numbered markers, captions and decorative accents separately.

1. Use a dedicated, booted simulator to avoid another Xcode session replacing the app during capture.
2. Build the app for testing into a chosen derived-data directory.
3. Run `python3 scripts/record-tutorial.py DEVICE_UDID English /tmp/tutorial-build /tmp/capture-en` (also `SimplifiedChinese` and `TraditionalChinese`).
4. Run `python3 scripts/tutorial-media.py /tmp/capture-en`. It exports kept XCTest screenshots, trims recordings using capture markers, preserves PNG/MP4 sources and encodes the public WebP assets. Requires Xcode, ffmpeg and the WebP command-line tools.
5. Keep source captures and public media together. Refresh captures whenever the depicted UI changes.

Animations load only after Play. Pause, leaving the view, backgrounding and Reduce Motion use the static poster. Decoded animations are memory-bounded. The announcement image is generated artwork in `FeatureTutorial.imageset`; action icons remain native SF Symbols.

## Screenshot refresh (2026-09-16)

All eight chapters now use 45 fresh simulator screenshots: 15 views in English, Simplified Chinese and Traditional Chinese. Every active media ID ends in `-20260916`, so existing cached screenshot URLs and historical demonstration recordings are no longer referenced. The references lesson uses its own capture with the Add button visible. Creation previews use the newly generated, bundled Bold Cartoon artwork.

Original PNGs live in `source/{locale}/*-20260916.png`; `capture-20260916.json` records each capture timestamp, test, device and source hash. Public WebP files preserve the real app pixels at 804 pixels wide. Mock services provide example content without live user accounts or paid generation.

To refresh all screenshots again:

1. Build the latest app and run `TutorialCaptureTests/testCaptureEnglish`, `testCaptureSimplifiedChinese` and `testCaptureTraditionalChinese` on a dedicated simulator. Wait for generated demo resources to be packaged before building.
2. Run `python3 scripts/export-tutorial-screenshots.py REVISION /path/to/results.xcresult`. The exporter requires all 45 captures; additional result bundles can supply focused reruns from the same app build.
3. Visually inspect every capture. Update all MDX media IDs to the new revision, using `create-references-REVISION` for the references lesson.
4. From `server`, run `bun run tutorial:compile`, `bun run test -- tests/unit/tutorial.test.ts`, and `bun x playwright test -c playwright.tutorial.config.ts`. Update the revision assertions alongside the media.
5. Run `TutorialNativeReaderTests/testRefreshedReferenceScreenshotsLoadInEveryLanguage` to verify the actual native reader displays the replaced images.

The full three-language capture run, six content checks, six browser/API checks, native reference-image verification in all three languages and TypeScript validation passed. Deployment remains a separate server release; the local tutorial server serves the new content and images.
