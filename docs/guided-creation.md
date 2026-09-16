# Guided sticker creation

The creation wizard keeps idea/photos, type, server-defined choice pages, optional animation settings, and overview in one draft. Generate is available only from the overview. Static is the default; style has no default, themes are optional, and enabling controls starts at Medium. The preview GIFs are rendered in advance with the same configuration resolver and renderer as saved stickers. Trying them requires no generation or credits.

## Rollout order

1. Apply `server/drizzle/0013_creation_presets.sql` through the normal server migration pipeline. Existing rows keep a null snapshot.
2. Deploy the server, including `GET /api/v1/creation-presets` and `public/images/creation/v1/` and `v2/`. Verify the public catalog, all twelve covers, and the 288 animated GIFs before releasing the app.
3. Release the updated iOS app. Older apps can continue sending creation requests without `presets`.

These instructions do not represent a production deployment having been performed.

## Editing the catalog

Edit `server/lib/creation-presets/catalog.ts`. Keep IDs stable, increment the catalog version whenever ordering, requirements, labels, prompts, or options change, and give replaced covers a new immutable URL. Group order controls page order. Supported types are `single_choice` and `multiple_choice`; Style initially requires one, Theme allows zero to two. Include English, Simplified Chinese, and Traditional Chinese labels/descriptions. No admin editor or client release is needed for additional supported groups.

The client fetches on opening, caches the last usable catalog, and on a stale-version response fetches fresh content, intersects selections with valid IDs, and requires review. A failed refresh keeps the draft and blocks generation. Unsupported optional types are skipped; unsupported required types require an app update.

Creation resolves IDs before project insertion. The saved snapshot owns labels, covers, shared guidance and option prompts for that project. Later catalog edits do not change saved projects. The display API excludes prompts. Read-only chips appear only above the initial user message (sequence 1), including after reopening; later messages have no repeated chips. All messages still use the project snapshot for agent guidance. The generation pipeline loads prompts separately from compacted chat history for routing, planning, layout, images, edits, and animation, including retries. Agents also receive every selected cover as a labelled visual example, alongside the user and saved reference images. Images load from versioned server assets using the saved snapshot; compaction retains these initial visual inputs. Artwork generation uses a labelled preset board; when all eight photo slots are occupied, the eighth photo and board share one input without dropping any photo or changing the first approved/source image. The orange cat is explicitly excluded as a subject reference. Presets preserve subject/reference identity and never authorize redesign of approved artwork.

## Assets and demo

`server/public/images/creation/v1/generation-prompts.json` records the original cover prompts. The version 2 catalog adds an optional animated preview and a complete pose/mood GIF matrix for every option. Static creation uses the original covers; animated creation plays the selected option's GIF. The animation page shows every selected style/theme example together, and its local controls switch all examples to the chosen pose/mood. Min/Medium/High/Ultra expose the first 2/3/5/8 poses. Changing the level demonstrates the last pose that level enables. Reduced motion holds a representative frame.

These previews are built with the app's actual `stickerGenerationWorkflow`: create project and reference attachment, run planning, inspect the static reference, confirm its plan, generate registered sprite sheets and expressions, and run the layout/configuration review. They are not manually authored motion recipes. Each option's versioned assets include the resulting document, artwork, GIFs and provenance manifest with its generation prompt, immutable preset guidance and job IDs. The approved plan records the individual pose and expression prompts. The local preparation database and object store are isolated from users' projects and billing; generation uses the configured real AI gateway.

From `server`, run `bun scripts/generate-creation-previews.ts <option-id> plan <work-directory>`, review `concept.png`, then run the same command with `build` and `export`. Failed builds use the normal checkpointed chat retry path. Export rejects motionless output and frames each pose with a single padded crop shared by all frames and moods, keeping the cat readable without changing its motion. Once all twelve are reviewed, `bun scripts/build-creation-demo.ts <work-directory>` packages the versioned server assets and the bundled Bold Cartoon control document, artwork and 24 GIFs. Generation never runs while a user tries the examples, so preview interactions spend no credits. Keep shipped URLs immutable and use a new asset version for regeneration.

Focused coverage lives in `creation-preview.test.ts`, `creation-presets.test.ts`, `workflow-creation-presets.test.ts`, `workflow-retry.test.ts`, `CreationPresetsTests.swift` and `CreationWizardUITests.swift`. The UI tests accept `CREATION_COVER_BASE_URL` to exercise actual served GIFs; otherwise they use the real bundled GIFs. Checks cover every generated pose/mood pair, changing selections, GIF playback after picker changes, all four levels, reduced motion and older catalog responses.
