#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
BUILD_ROOT=${STICKER_FACTORY_TEST_ROOT:-/private/tmp/sticker-factory-ios-tests}
PACKAGE_ROOT=${STICKER_FACTORY_PACKAGE_ROOT:-/private/tmp/sticker-factory-packages}
MODULE_CACHE=${BUILD_ROOT}/ModuleCache
SIMULATOR_ID=${STICKER_FACTORY_SIMULATOR_ID:-}

mkdir -p "${BUILD_ROOT}" "${PACKAGE_ROOT}" "${MODULE_CACHE}"
export CLANG_MODULE_CACHE_PATH=${MODULE_CACHE}
export SWIFTPM_MODULECACHE_OVERRIDE=${MODULE_CACHE}

if [[ -z "${SIMULATOR_ID}" ]]; then
  SIMULATOR_ID=$(xcrun simctl list devices available | awk -F '[()]' '/(iPhone|iPad)/ { print $2; exit }')
fi

if [[ -z "${SIMULATOR_ID}" ]]; then
  print -u2 "No available iPhone or iPad simulator was found. Set STICKER_FACTORY_SIMULATOR_ID to run tests."
  exit 2
fi

xcodebuild \
  -project "${PROJECT_ROOT}/StickerGeniOS.xcodeproj" \
  -scheme StickerGeniOS \
  -destination "id=${SIMULATOR_ID}" \
  -derivedDataPath "${BUILD_ROOT}/DerivedData" \
  -clonedSourcePackagesDirPath "${PACKAGE_ROOT}" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test

print -u2 "StickerMessagesTests is intentionally not executed: an .appex executable is not a valid XCTest TEST_HOST. The extension-safe sources compile in the StickerMessages build; executable unit tests require moving them into a shared framework or package hosted by the containing app."
