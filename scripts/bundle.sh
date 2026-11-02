#!/bin/zsh
# Builds build/Gifwin.app: the one place Screen Recording is granted.
#
#   scripts/bundle.sh                       build and sign (ad-hoc)
#   scripts/bundle.sh --install             also copy to ~/Applications and link ~/.local/bin/gifwin
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/bundle.sh
#
# Ad-hoc signing gives the app no stable identity, so macOS forgets the Screen Recording grant
# every time the binary changes. A real certificate (Developer ID or Apple Development) keeps it.
set -euo pipefail
cd "${0:A:h}/.."

BUNDLE_ID="${BUNDLE_ID:-io.github.mriver15.gifwin}"
VERSION="$(grep -o 'version = "[0-9.]*"' Sources/GifwinCore/Command.swift | head -1 | grep -o '[0-9.]*')"
IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Gifwin.app"

swift build -c release 2>&1 | grep -E 'error|Compiling|Build complete' | tail -1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/gifwin "$APP/Contents/MacOS/gifwin"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Gifwin</string>
    <key>CFBundleDisplayName</key><string>Gifwin</string>
    <key>CFBundleExecutable</key><string>gifwin</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --options runtime --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "built $APP ($VERSION), signed with: $([[ "$IDENTITY" == "-" ]] && echo 'ad-hoc' || echo "$IDENTITY")"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature|TeamIdentifier|CDHash' | sed 's/^/  /'
du -sh "$APP/Contents/MacOS/gifwin" | awk '{print "  binary: " $1}'

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications" "$HOME/.local/bin"
    "$APP/Contents/MacOS/gifwin" quit 2>/dev/null || true
    rm -rf "$HOME/Applications/Gifwin.app"
    cp -R "$APP" "$HOME/Applications/Gifwin.app"
    ln -sf "$HOME/Applications/Gifwin.app/Contents/MacOS/gifwin" "$HOME/.local/bin/gifwin"
    echo "installed ~/Applications/Gifwin.app and linked ~/.local/bin/gifwin"
fi
