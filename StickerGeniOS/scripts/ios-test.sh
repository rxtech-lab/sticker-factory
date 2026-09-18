#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
BUILD_ROOT=${STICKER_FACTORY_TEST_ROOT:-/private/tmp/sticker-factory-ios-tests}
PACKAGE_ROOT=${STICKER_FACTORY_PACKAGE_ROOT:-/private/tmp/sticker-factory-packages}
MODULE_CACHE=${BUILD_ROOT}/ModuleCache
SIMULATOR_ID=${STICKER_FACTORY_SIMULATOR_ID:-}
SIMULATOR_NAME=${STICKER_FACTORY_SIMULATOR_NAME:-}

# What runs is decided by a test plan in StickerGeniOS/TestPlans, never by an -only-testing filter:
# the plan is the same object Xcode opens, so a suite cannot be in CI but missing from the IDE.
SCHEME=${STICKER_FACTORY_SCHEME:-StickerGeniOS}
TEST_PLAN=${STICKER_FACTORY_TEST_PLAN:-AllTests}

# Parallel testing clones the destination simulator once per worker. The UI tests are safe to clone
# because --ui-testing swaps the network client for an in-process mock: no ports, no shared files.
# One worker per two cores leaves the host room for the simulators' own daemons; more workers than
# that and the clones contend for CPU and start failing on timing rather than on behaviour.
PARALLEL=${STICKER_FACTORY_PARALLEL:-1}
if [[ -n "${STICKER_FACTORY_TEST_WORKERS:-}" ]]; then
  WORKERS=${STICKER_FACTORY_TEST_WORKERS}
else
  WORKERS=$(( $(sysctl -n hw.ncpu) / 2 ))
  (( WORKERS < 1 )) && WORKERS=1
  (( WORKERS > 4 )) && WORKERS=4
fi

PARALLEL_ARGS=(-parallel-testing-enabled NO)
if [[ "${PARALLEL}" == "1" ]]; then
  PARALLEL_ARGS=(
    -parallel-testing-enabled YES
    -parallel-testing-worker-count "${WORKERS}"
  )
fi

RESULT_BUNDLE_ARGS=()
if [[ -n "${STICKER_FACTORY_RESULT_BUNDLE:-}" ]]; then
  rm -rf "${STICKER_FACTORY_RESULT_BUNDLE}"
  RESULT_BUNDLE_ARGS=(-resultBundlePath "${STICKER_FACTORY_RESULT_BUNDLE}")
fi

mkdir -p "${BUILD_ROOT}" "${PACKAGE_ROOT}" "${MODULE_CACHE}"
export CLANG_MODULE_CACHE_PATH=${MODULE_CACHE}
export SWIFTPM_MODULECACHE_OVERRIDE=${MODULE_CACHE}

if [[ -n "${SIMULATOR_ID}" ]]; then
  DESTINATION="id=${SIMULATOR_ID}"
elif [[ -n "${SIMULATOR_NAME}" ]]; then
  DESTINATION="platform=iOS Simulator,name=${SIMULATOR_NAME}"
else
  SIMULATOR_ID=$(xcodebuild \
    -project "${PROJECT_ROOT}/StickerGeniOS.xcodeproj" \
    -scheme "${SCHEME}" \
    -clonedSourcePackagesDirPath "${PACKAGE_ROOT}" \
    -disableAutomaticPackageResolution \
    -showdestinations 2>/dev/null \
    | awk '/platform:iOS Simulator, arch:/ && /name:iPhone/ && match($0, /id:[^,]+/) { id = substr($0, RSTART + 3, RLENGTH - 3); gsub(/[[:space:]]/, "", id); print id; exit }')
  DESTINATION="id=${SIMULATOR_ID}"
fi

if [[ -z "${SIMULATOR_ID}" && -z "${SIMULATOR_NAME}" ]]; then
  print -u2 "No iPhone simulator supported by the ${SCHEME} scheme was found. Set STICKER_FACTORY_SIMULATOR_ID or STICKER_FACTORY_SIMULATOR_NAME to run tests."
  exit 2
fi

if [[ -z "${DESTINATION}" ]]; then
  print -u2 "No simulator destination was configured."
  exit 2
fi

print -u2 "Running test plan ${TEST_PLAN} on scheme ${SCHEME} (${DESTINATION}), parallel=${PARALLEL} workers=${WORKERS}"

xcodebuild \
  -project "${PROJECT_ROOT}/StickerGeniOS.xcodeproj" \
  -scheme "${SCHEME}" \
  -testPlan "${TEST_PLAN}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${BUILD_ROOT}/DerivedData" \
  -clonedSourcePackagesDirPath "${PACKAGE_ROOT}" \
  -disableAutomaticPackageResolution \
  "${PARALLEL_ARGS[@]}" \
  "${RESULT_BUNDLE_ARGS[@]}" \
  -retry-tests-on-failure \
  -test-iterations "${STICKER_FACTORY_TEST_ITERATIONS:-2}" \
  CODE_SIGNING_ALLOWED=NO \
  test

print -u2 "StickerMessagesTests is intentionally not executed: an .appex executable is not a valid XCTest TEST_HOST. The extension-safe sources compile in the StickerMessages build; executable unit tests require moving them into a shared framework or package hosted by the containing app."
