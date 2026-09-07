#!/bin/sh
set -eu
# Local compile-only validation can explicitly opt out of external symbol upload.
if [ "${STICKER_FACTORY_SKIP_CRASHLYTICS_UPLOAD:-NO}" = "YES" ]; then
    echo "Crashlytics symbol upload disabled for this build."
    exit 0
fi
# Support both Xcode's default package checkout and the repository build scripts.
for package_root in "${SOURCE_PACKAGES_DIR_PATH:-}" "${BUILD_DIR%/Build/*}/SourcePackages" "${STICKER_FACTORY_PACKAGE_ROOT:-/private/tmp/sticker-factory-packages}"; do
    if [ -n "$package_root" ] && [ -f "$package_root/checkouts/firebase-ios-sdk/Crashlytics/run" ]; then
        exec "$package_root/checkouts/firebase-ios-sdk/Crashlytics/run"
    fi
done
echo "error: Firebase Crashlytics package checkout not found. Resolve Swift packages before building." >&2
exit 1
