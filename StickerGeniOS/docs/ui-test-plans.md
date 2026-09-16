# iOS UI test plans

What runs in CI is decided by the `.xctestplan` files in `StickerGeniOS/TestPlans`, not by an
`-only-testing` filter in a shell script. A plan is the same object Xcode's test navigator opens, so
a suite cannot be running in CI but invisible in the IDE, or vice versa.

## The plans

| Plan | Scheme | Contents | Runs in CI |
| --- | --- | --- | --- |
| `UITests` | `StickerGeniOS` | `StickerGeniOSUITests`, minus the three server-backed tutorial classes | every push |
| `AppClipUITests` | `StickerAppClip` | `StickerAppClipUITests` | every push |
| `UnitTests` | `StickerGeniOS` | `StickerGeniOSTests` | no — available to `make test-unit` |
| `AllTests` | `StickerGeniOS` | `UnitTests` + `UITests`; the scheme default, so a bare `xcodebuild test` still runs everything | no |
| `TutorialUITests` | `StickerGeniOS` | `TutorialCaptureTests`, `TutorialNativeReaderTests`, `TutorialUITests` | `workflow_dispatch` only |

### Why the tutorial classes are held out of the push path

All three read `api/v1/tutorial/{locale}` over HTTP from a Next.js server on `127.0.0.1:3117`:
`TutorialCoordinator` honours `TUTORIAL_BASE_URL` under `--ui-testing`, and each class sets it in its
own `setUp`. No iOS job started that server, so they could only fail there. Running them takes an
explicit `workflow_dispatch` with `run_tutorial_plan`, which boots the server first.

The membership test is mechanical, so use it rather than judging by name — `TutorialUITests` sounds
like a tips-only suite but asserts on `tutorial-sheet` and `tutorial-chapter-*`, which only exist once
the fetched document renders:

```sh
grep -l TUTORIAL_BASE_URL StickerGeniOSUITests/*.swift
```

Anything that grep lists belongs in `TutorialUITests.xctestplan` and in the other plans'
`skippedTests`.

## Parallel execution

The UI plans set `"parallelizable": true`, and `ios-test.sh` passes `-parallel-testing-enabled YES`
with a worker count, so `xcodebuild` clones the destination simulator once per worker and distributes
the suite across the clones.

This is only safe because `--ui-testing` swaps `StickerAPIClient` for an in-process
`MockStickerAPIClient` (see `AppEnvironment.swift`): the tests touch no network, no fixed port and no
shared file on the host, so two clones cannot collide. The tutorial plan is the exception — every one
of its tests drives the same localhost server, so it runs with `STICKER_FACTORY_PARALLEL=0`.

Worker count defaults to half the machine's cores, capped at 4. Simulator clones are heavy; past that
ratio they contend for CPU and UI tests start failing on timing rather than on behaviour. Override
with `STICKER_FACTORY_TEST_WORKERS`.

### A class is the unit of parallelism — keep them small

**XCTest distributes UI tests per class, not per test method.** One class runs on one simulator clone
no matter how many workers are free, so the longest single class sets the floor on the job's
wall-clock. This was measured, not assumed: a 30-test class asked for 3 workers put all 30 tests on
`Clone 1`.

The test plan's `parallelizationMode` key does not change this for XCTest, which is why no plan sets
it — a key that implies a granularity the runner ignores is worse than no key.

So the suites are split by subject, and the split is load-bearing rather than cosmetic:

| Suite | Classes |
| --- | --- |
| `StickerGeniOSUITests` | `StickerPlanUITests`, `SubscriptionUITests`, `LibraryUITests`, `CreationPreviewUITests`, `ChatUITests`, `ChatToolSheetUITests`, `PackDetailUITests` |
| `StickerAppClipUITests` | `ClipLibraryUITests`, `ClipGenerationUITests`, `ClipAuthenticationUITests`, `ClipPackURLUITests`, `ClipURLValidationUITests` |

Each inherits shared setup and helpers from `StickerGeniOSUITestCase` / `ClipUITestCase`. Splitting
the App Clip suite took it from 229s on one clone to 140s across four.

When adding tests, prefer a new class over growing an existing one past roughly a minute of runtime,
and group by the surface under test so the name still says what broke. Balance by *duration*, not by
test count — the per-test seconds in any run's log are the input.

## Running them

```sh
make test            # AllTests  — unit + UI
make test-ui         # UITests   — exactly what CI runs on a push
make test-unit       # UnitTests
make test-appclip    # AppClipUITests
make test-tutorial   # TutorialUITests; start the server below first
```

The tutorial plan needs its content server:

```sh
cd server && STICKER_FACTORY_TUTORIAL_PREVIEW=true bun x next dev -p 3117
```

`ios-test.sh` reads these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `STICKER_FACTORY_SCHEME` | `StickerGeniOS` | scheme to test |
| `STICKER_FACTORY_TEST_PLAN` | `AllTests` | plan to run |
| `STICKER_FACTORY_PARALLEL` | `1` | `0` forces a single simulator |
| `STICKER_FACTORY_TEST_WORKERS` | `min(cores/2, 4)` | exact worker count |
| `STICKER_FACTORY_SIMULATOR_NAME` / `_ID` | first available iPhone | destination |
| `STICKER_FACTORY_RESULT_BUNDLE` | unset | write an `.xcresult` here |

## Adding a test

A new `XCTestCase` in `StickerGeniOSUITests` needs no wiring: the plans list targets and skip
exceptions rather than enumerating tests, and the folder is a synchronized group, so both the plan and
the Xcode target pick it up. Add to `skippedTests` only for a test that cannot run unattended — and
say why, as the two tutorial classes do above.

`StickerAppClipUITests` is **not** a synchronized group: a new file there must also be added to the
target in `project.pbxproj`, or it compiles nowhere and silently never runs.

## Known limit

`StickerMessagesTests` is still not executed by any plan: an `.appex` executable is not a valid
XCTest `TEST_HOST`. Those sources are compile-checked through the `StickerMessages` build. Running
them means moving the logic into a shared framework or package hosted by the containing app.
