#!/bin/bash
# Build a native macOS app using Apple's installed Swift toolchain.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUTPUT_DIRECTORY="$PROJECT_ROOT/dist"
UNIVERSAL=false
MAKE_DMG=false
OPEN_APP=false
RUN_TESTS=false
STAGING_DIRECTORY=""

usage() {
    cat <<'HELP'
Usage: scripts/build-app.sh [--universal] [--dmg] [--open] [--test] [--output DIR]

  --universal   Build for both Apple silicon and Intel Macs.
  --dmg         Also make dist/MotionPhotoBridge.dmg with an Applications shortcut.
  --open        Open the completed app and reveal it in Finder.
  --test        Run the Swift test suite before building.
  --output DIR  Place the finished app and optional disk image in DIR.

Requires macOS 13 or newer and Xcode 15 / Swift 5.9 or newer.
Command Line Tools with a compatible macOS SDK also work.
By default the app is signed locally (ad hoc). To sign a distribution build:
  MOTIONPHOTOBRIDGE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
    scripts/build-app.sh --universal --dmg
Notarization is a separate step; this script does not upload anything.
HELP
}

fail() { printf '\n%s\n' "$*" >&2; exit 1; }
cleanup() {
    if [[ -n "$STAGING_DIRECTORY" && -d "$STAGING_DIRECTORY" ]]; then
        # If installing the prepared app failed after moving aside an older
        # build, restore that build before removing this temporary directory.
        if [[ -d "$STAGING_DIRECTORY/previous-MotionPhotoBridge.app" && ! -e "$OUTPUT_DIRECTORY/MotionPhotoBridge.app" ]]; then
            if ! mv "$STAGING_DIRECTORY/previous-MotionPhotoBridge.app" "$OUTPUT_DIRECTORY/MotionPhotoBridge.app"; then
                printf 'The previous app was kept at: %s\n' "$STAGING_DIRECTORY/previous-MotionPhotoBridge.app" >&2
                return
            fi
        fi
        rm -rf -- "$STAGING_DIRECTORY"
    fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --universal) UNIVERSAL=true ;;
        --dmg) MAKE_DMG=true ;;
        --open) OPEN_APP=true ;;
        --test) RUN_TESTS=true ;;
        --output)
            [[ $# -ge 2 && -n "$2" ]] || fail "--output needs a directory."
            OUTPUT_DIRECTORY="$2"
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; fail "Unknown option: $1" ;;
    esac
    shift
done

[[ "$(uname -s)" == "Darwin" ]] || fail "This app uses macOS frameworks. Run this build script on a Mac."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$MACOS_MAJOR" -ge 13 ]] || fail "MotionPhotoBridge needs macOS 13 (Ventura) or newer."
command -v xcrun >/dev/null || fail "Install Xcode or Apple's Command Line Tools, then run this again."
if ! xcrun --find swift >/dev/null 2>&1 || ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    fail "Apple's Swift compiler or macOS SDK is missing. Install Xcode 15 or newer, or run 'xcode-select --install' in Terminal, then try again."
fi

printf 'Building MotionPhotoBridge with %s\n' "$(xcrun swift --version | head -1)"
mkdir -p -- "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd -P)"
STAGING_DIRECTORY="$(mktemp -d "$OUTPUT_DIRECTORY/.MotionPhotoBridge-build.XXXXXX")"
APP_STAGING="$STAGING_DIRECTORY/MotionPhotoBridge.app"
APP_DESTINATION="$OUTPUT_DIRECTORY/MotionPhotoBridge.app"
mkdir -p "$APP_STAGING/Contents/MacOS" "$APP_STAGING/Contents/Resources"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_STAGING/Contents/Info.plist"
printf 'APPL????' > "$APP_STAGING/Contents/PkgInfo"

cd "$PROJECT_ROOT"
if [[ "$RUN_TESTS" == true ]]; then
    xcrun swift test --package-path "$PROJECT_ROOT"
fi

if [[ "$UNIVERSAL" == true ]]; then
    # Separate builds work with both the native SwiftPM build system and newer
    # Swift Build releases. Never assume the toolchain's output directory layout.
    for TARGET_ARCHITECTURE in arm64 x86_64; do
        printf '\nBuilding %s…\n' "$TARGET_ARCHITECTURE"
        xcrun swift build --package-path "$PROJECT_ROOT" --configuration release \
            --product MotionPhotoBridge --arch "$TARGET_ARCHITECTURE"
        BINARY_DIRECTORY="$(xcrun swift build --package-path "$PROJECT_ROOT" \
            --configuration release --arch "$TARGET_ARCHITECTURE" --show-bin-path)"
        cp "$BINARY_DIRECTORY/MotionPhotoBridge" "$STAGING_DIRECTORY/MotionPhotoBridge-$TARGET_ARCHITECTURE"
    done
    xcrun lipo -create "$STAGING_DIRECTORY/MotionPhotoBridge-arm64" \
        "$STAGING_DIRECTORY/MotionPhotoBridge-x86_64" \
        -output "$APP_STAGING/Contents/MacOS/MotionPhotoBridge"
else
    xcrun swift build --package-path "$PROJECT_ROOT" --configuration release --product MotionPhotoBridge
    BINARY_DIRECTORY="$(xcrun swift build --package-path "$PROJECT_ROOT" --configuration release --show-bin-path)"
    cp "$BINARY_DIRECTORY/MotionPhotoBridge" "$APP_STAGING/Contents/MacOS/MotionPhotoBridge"
fi
chmod +x "$APP_STAGING/Contents/MacOS/MotionPhotoBridge"

printf '\nCreating app icon…\n'
xcrun swift "$PROJECT_ROOT/scripts/make-icon.swift" "$STAGING_DIRECTORY/AppIcon.iconset"
iconutil --convert icns "$STAGING_DIRECTORY/AppIcon.iconset" \
    --output "$APP_STAGING/Contents/Resources/AppIcon.icns"

plutil -lint "$APP_STAGING/Contents/Info.plist"
if [[ -n "${MOTIONPHOTOBRIDGE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$MOTIONPHOTOBRIDGE_SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "$PROJECT_ROOT/Resources/MotionPhotoBridge.entitlements" "$APP_STAGING"
else
    codesign --force --sign - \
        --entitlements "$PROJECT_ROOT/Resources/MotionPhotoBridge.entitlements" "$APP_STAGING"
fi
codesign --verify --strict --verbose=2 "$APP_STAGING"

# Replace only this project's completed build after the new bundle is ready.
if [[ -e "$APP_DESTINATION" ]]; then
    [[ -d "$APP_DESTINATION" && ! -L "$APP_DESTINATION" ]] || fail "The output path already exists and is not an app directory: $APP_DESTINATION"
    mv "$APP_DESTINATION" "$STAGING_DIRECTORY/previous-MotionPhotoBridge.app"
fi
mv "$APP_STAGING" "$APP_DESTINATION"

if [[ "$MAKE_DMG" == true ]]; then
    mkdir "$STAGING_DIRECTORY/disk-image"
    ditto "$APP_DESTINATION" "$STAGING_DIRECTORY/disk-image/MotionPhotoBridge.app"
    ln -s /Applications "$STAGING_DIRECTORY/disk-image/Applications"
    hdiutil create -volname MotionPhotoBridge -srcfolder "$STAGING_DIRECTORY/disk-image" \
        -format UDZO -ov "$OUTPUT_DIRECTORY/MotionPhotoBridge.dmg"
fi

printf '\nCreated: %s\n' "$APP_DESTINATION"
printf 'Architectures: '
xcrun lipo -archs "$APP_DESTINATION/Contents/MacOS/MotionPhotoBridge"
if [[ -z "${MOTIONPHOTOBRIDGE_SIGN_IDENTITY:-}" ]]; then
    printf 'This is a locally signed build for your Mac. Public distribution needs Developer ID signing and notarization.\n'
fi
if [[ "$OPEN_APP" == true ]]; then
    open -R "$APP_DESTINATION"
    open "$APP_DESTINATION"
fi
