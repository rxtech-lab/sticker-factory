#!/bin/bash

# Xcode Cloud post-clone hook.
# Stamps the app version from the git tag that triggered the build:
#   CI_TAG=v1.2.3 -> MARKETING_VERSION=1.2.3
# and, when present, uses Xcode Cloud's auto-incrementing CI_BUILD_NUMBER for
# CURRENT_PROJECT_VERSION. Both the app and the iMessage extension targets are
# stamped so their versions stay in lockstep.
#
# This only rewrites the working copy on the CI machine; nothing is committed
# back to git, so project.pbxproj stays at its checked-in values locally.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IOS_PROJECT_FILE="$IOS_PROJECT_DIR/StickerGeniOS.xcodeproj/project.pbxproj"

echo "== Xcode Cloud: ci_post_clone =="
echo "Project dir: $IOS_PROJECT_DIR"

if [[ -n "${CI_TAG:-}" ]]; then
  VERSION="${CI_TAG#v}"

  if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ]]; then
    echo "Stamping iOS version from CI_TAG: $CI_TAG -> $VERSION"
    IOS_PROJECT_FILE="$IOS_PROJECT_FILE" \
      "$IOS_PROJECT_DIR/scripts/update-ios-version.sh" "$VERSION" "${CI_BUILD_NUMBER:-}"
  else
    echo "CI_TAG '$CI_TAG' is not a semver tag; skipping version stamping"
  fi
else
  echo "CI_TAG not set; skipping version stamping"
fi

echo "ci_post_clone completed"
