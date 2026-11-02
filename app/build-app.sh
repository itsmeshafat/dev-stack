#!/usr/bin/env bash
# build-app.sh — compiles the SwiftUI app, generates the .icns, bundles + signs it.
#   app/build-app.sh [output-app-path]   (default: /Applications/Dev Stack.app)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-/Applications/Dev Stack.app}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== icon =="
mkdir -p "$HERE/Assets"
/usr/bin/swiftc -O -o "$WORK/makeicon" "$HERE/makeicon.swift" -framework AppKit
"$WORK/makeicon" "$WORK/icon_1024.png" >/dev/null
cp "$WORK/icon_1024.png" "$HERE/Assets/icon-1024.png"

ICONSET="$WORK/AppIcon.iconset"; mkdir -p "$ICONSET"
mk() { /usr/bin/sips -z "$1" "$1" "$WORK/icon_1024.png" --out "$ICONSET/$2" >/dev/null; }
mk 16  icon_16x16.png
mk 32  icon_16x16@2x.png
mk 32  icon_32x32.png
mk 64  icon_32x32@2x.png
mk 128 icon_128x128.png
mk 256 icon_128x128@2x.png
mk 256 icon_256x256.png
mk 512 icon_256x256@2x.png
mk 512 icon_512x512.png
cp "$WORK/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
/usr/bin/iconutil -c icns "$ICONSET" -o "$HERE/Assets/AppIcon.icns"

echo "== bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# bundle the single-source help document (docs/HELP.md) into the app
cp "$HERE/../docs/HELP.md" "$APP/Contents/Resources/HELP.md"

echo "== compile =="
/usr/bin/swiftc -O -parse-as-library -o "$APP/Contents/MacOS/DevStack" "$HERE/main.swift" \
  -framework SwiftUI -framework AppKit

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dev Stack</string>
  <key>CFBundleDisplayName</key><string>Dev Stack</string>
  <key>CFBundleIdentifier</key><string>io.github.devstack.app</string>
  <key>CFBundleVersion</key><string>1.3.0</string>
  <key>CFBundleShortVersionString</key><string>1.3.0</string>
  <key>CFBundleExecutable</key><string>DevStack</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP" 2>/dev/null || true
touch "$APP"
echo "built: $APP"
