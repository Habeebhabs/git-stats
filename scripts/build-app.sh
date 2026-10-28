#!/bin/zsh
# Builds Worklog.app (release, ad-hoc signed) into ./build/.
#   scripts/build-app.sh          # build
#   scripts/build-app.sh --open   # build and launch
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release --product Worklog
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Worklog.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Worklog" "$APP/Contents/MacOS/Worklog"
# Fonts (and anything else in the SwiftPM resource bundle)
if [[ -d "$BIN/Worklog_Worklog.bundle" ]]; then
  cp -R "$BIN/Worklog_Worklog.bundle" "$APP/Contents/Resources/"
fi
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$ROOT"/Sources/Worklog/Resources/Fonts/*.otf "$APP/Contents/Resources/Fonts/"

VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Worklog</string>
  <key>CFBundleDisplayName</key><string>Worklog</string>
  <key>CFBundleIdentifier</key><string>dev.habeeb.worklog</string>
  <key>CFBundleExecutable</key><string>Worklog</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--open" ]]; then
  open "$APP"
fi
