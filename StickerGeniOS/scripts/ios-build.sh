#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
BUILD_ROOT=${STICKER_FACTORY_BUILD_ROOT:-/private/tmp/sticker-factory-ios-build}
PACKAGE_ROOT=${STICKER_FACTORY_PACKAGE_ROOT:-/private/tmp/sticker-factory-packages}
MODULE_CACHE=${BUILD_ROOT}/ModuleCache

mkdir -p "${BUILD_ROOT}" "${PACKAGE_ROOT}" "${MODULE_CACHE}"
export CLANG_MODULE_CACHE_PATH=${MODULE_CACHE}
export SWIFTPM_MODULECACHE_OVERRIDE=${MODULE_CACHE}

xcodebuild \
  -project "${PROJECT_ROOT}/StickerGeniOS.xcodeproj" \
  -scheme StickerGeniOS \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${BUILD_ROOT}/DerivedData" \
  -clonedSourcePackagesDirPath "${PACKAGE_ROOT}" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  build
