#!/bin/sh
# Builds "Quick Term.app" into ./build.
#
#   ./build.sh            build the app
#   ./build.sh --install  also copy it to /Applications and (re)launch it
set -eu
cd "$(dirname "$0")"

GHOSTTY=vendor/ghostty
APP="build/Quick Term.app"

# libghostty is built from source once; delete vendor/ghostty to update it.
if [ ! -d "$GHOSTTY/macos/GhosttyKit.xcframework" ]; then
    if [ ! -d "$GHOSTTY" ]; then
        git clone --depth 1 https://github.com/ghostty-org/ghostty.git "$GHOSTTY"
        # Local changes to libghostty; each patch says what it is for.
        for patch in patches/*.patch; do
            git -C "$GHOSTTY" apply "$PWD/$patch"
        done
    fi
    (cd "$GHOSTTY" && zig build \
        -Demit-xcframework=true -Demit-macos-app=false \
        -Dxcframework-target=native -Doptimize=ReleaseFast)
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QuickTerm "$APP/Contents/MacOS/QuickTerm"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# libghostty locates its resources by finding terminfo next to a "ghostty"
# directory inside Contents/Resources.
cp -R "$GHOSTTY/zig-out/share/ghostty" "$APP/Contents/Resources/ghostty"
cp -R "$GHOSTTY/zig-out/share/terminfo" "$APP/Contents/Resources/terminfo"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x QuickTerm 2>/dev/null || true
    rm -rf "/Applications/Quick Term.app"
    cp -R "$APP" "/Applications/Quick Term.app"
    open "/Applications/Quick Term.app" --args --hidden
    echo "Installed and launched /Applications/Quick Term.app"
fi
