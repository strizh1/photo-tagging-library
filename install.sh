#!/bin/zsh
# Builds a Release copy of the app and installs it in /Applications, so it can be
# launched from Spotlight / Launchpad / the Dock without opening Xcode.
# Re-run after making changes to update the installed app. Quit the app first.
set -euo pipefail

cd "$(dirname "$0")"

# xcodebuild needs the full Xcode, not just the Command Line Tools. Use Xcode for
# this script only, without changing the system-wide `xcode-select` setting.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" != *.app/* ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

BUILD_DIR="$(mktemp -d)"
APP_NAME="photos analyze.app"

# Optional private signing settings (git-ignored), e.g.
#   DEVELOPMENT_TEAM=ABCDE12345
#   BUNDLE_ID=com.yourname.photos-analyze
#   APP_ICON=PrivateAppIcon     (an icon set in Assets.xcassets to use instead of AppIcon)
# Without them the app is signed to run locally on this Mac only.
SETTINGS=()
if [[ -f signing.local.env ]]; then
    source signing.local.env
    [[ -n "${DEVELOPMENT_TEAM:-}" ]] && SETTINGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
    [[ -n "${BUNDLE_ID:-}" ]] && SETTINGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
    [[ -n "${APP_ICON:-}" ]] && SETTINGS+=("ASSETCATALOG_COMPILER_APPICON_NAME=$APP_ICON")
fi

echo "Building Release (the first build takes a few minutes)…"
xcodebuild -scheme "photos analyze" -configuration Release \
    -derivedDataPath "$BUILD_DIR" "${SETTINGS[@]}" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

if [[ ! -d "$BUILD_DIR/Build/Products/Release/$APP_NAME" ]]; then
    echo "Build failed." >&2
    exit 1
fi

echo "Installing…"
rm -rf "/Applications/$APP_NAME"
ditto "$BUILD_DIR/Build/Products/Release/$APP_NAME" "/Applications/$APP_NAME"
rm -rf "$BUILD_DIR"

echo "Installed to /Applications/$APP_NAME"
