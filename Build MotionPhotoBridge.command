#!/bin/bash
# Double-click this file in Finder to build and open MotionPhotoBridge.
set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
printf 'MotionPhotoBridge — build for this Mac\n\n'
if /bin/bash "$PROJECT_ROOT/scripts/build-app.sh" --open; then
    printf '\nAll done. You can drag MotionPhotoBridge.app from the dist folder into Applications.\n'
else
    BUILD_EXIT_CODE=$?
    printf '\nThe build did not finish. The error above explains what needs attention.\n'
    printf 'If developer tools are missing, install Xcode 15 or newer, or run:\n  xcode-select --install\n'
    printf '\nPress Return to close this window.\n'
    read -r _ || true
    exit "$BUILD_EXIT_CODE"
fi
printf '\nPress Return to close this window.\n'
read -r _ || true
