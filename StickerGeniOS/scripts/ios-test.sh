#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
BUILD_ROOT=${STICKER_FACTORY_TEST_ROOT:-/private/tmp/sticker-factory-ios-tests}
PACKAGE_ROOT=${STICKER_FACTORY_PACKAGE_ROOT:-/private/tmp/sticker-factory-packages}
MODULE_CACHE=${BUILD_ROOT}/ModuleCache
SIMULATOR_ID=${STICKER_FACTORY_SIMULATOR_ID:-}
SIMULATOR_NAME=${STICKER_FACTORY_SIMULATOR_NAME:-}
TEST_FILTER_ARGS=()

if [[ "${STICKER_FACTORY_UI_TESTS_ONLY:-0}" == "1" ]]; then
  TEST_FILTER_ARGS=(-only-testing:StickerGeniOSUITests)
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
    -scheme StickerGeniOS \
    -clonedSourcePackagesDirPath "${PACKAGE_ROOT}" \
    -disableAutomaticPackageResolution \
    -showdestinations 2>/dev/null \
    | awk '/platform:iOS Simulator, arch:/ && /name:iPhone/ && match($0, /id:[^,]+/) { id = substr($0, RSTART + 3, RLENGTH - 3); gsub(/[[:space:]]/, "", id); print id; exit }')
  DESTINATION="id=${SIMULATOR_ID}"
fi

if [[ -z "${SIMULATOR_ID}" ]]; then
  if [[ -z "${SIMULATOR_NAME}" ]]; then
    print -u2 "No iPhone simulator supported by the StickerGeniOS scheme was found. Set STICKER_FACTORY_SIMULATOR_ID or STICKER_FACTORY_SIMULATOR_NAME to run tests."
    exit 2
  fi
fi

if [[ -z "${DESTINATION}" ]]; then
  print -u2 "No simulator destination was configured."
  exit 2
fi

xcodebuild \
  -project "${PROJECT_ROOT}/StickerGeniOS.xcodeproj" \
  -scheme StickerGeniOS \
  -destination "${DESTINATION}" \
  -derivedDataPath "${BUILD_ROOT}/DerivedData" \
  -clonedSourcePackagesDirPath "${PACKAGE_ROOT}" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  "${TEST_FILTER_ARGS[@]}" \
  test

print -u2 "StickerMessagesTests is intentionally not executed: an .appex executable is not a valid XCTest TEST_HOST. The extension-safe sources compile in the StickerMessages build; executable unit tests require moving them into a shared framework or package hosted by the containing app."
