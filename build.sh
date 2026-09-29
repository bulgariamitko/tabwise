#!/bin/bash
# Builds Tabwise.app into ./build.noindex for local use (signed with your Apple Development certificate).
# `./build.sh install` also copies it to /Applications. For a public release use ./release.sh.
set -euo pipefail
cd "$(dirname "$0")"

SCRATCH="$HOME/Library/Caches/Tabwise-build"   # keep build products out of Dropbox
APP="build.noindex/Tabwise.app"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
UNIVERSAL="${UNIVERSAL:-0}"   # 1 = Apple Silicon + Intel in one binary (for releases)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
if [ "$UNIVERSAL" = "1" ]; then
  # SwiftTerm's build plugin breaks multi-arch builds, so build each architecture and merge.
  for t in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do swift build -c release --scratch-path "$SCRATCH" --triple $t; done
  lipo -create -output "$APP/Contents/MacOS/Tabwise" \
    "$SCRATCH/arm64-apple-macosx/release/Tabwise" "$SCRATCH/x86_64-apple-macosx/release/Tabwise"
else
  swift build -c release --scratch-path "$SCRATCH"
  cp "$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/Tabwise" "$APP/Contents/MacOS/Tabwise"
fi
# Sparkle (auto-updates) ships inside the app.
ditto "$SCRATCH/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
  "$APP/Contents/Frameworks/Sparkle.framework"

# Icon (regenerated only when missing).
if [ ! -f build.noindex/AppIcon.icns ]; then
  ICONSET="$SCRATCH/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$SCRATCH/icon.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$SCRATCH/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$SCRATCH/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build.noindex/AppIcon.icns
fi
cp build.noindex/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/statusline.sh "$APP/Contents/Resources/statusline.sh"   # built-in status line
chmod +x "$APP/Contents/Resources/statusline.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tabwise</string>
  <key>CFBundleDisplayName</key><string>Tabwise</string>
  <key>CFBundleIdentifier</key><string>com.dimitarklaturov.tabwise</string>
  <key>CFBundleExecutable</key><string>Tabwise</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Dimitar Klaturov. MIT License.</string>
  <key>NSMicrophoneUsageDescription</key><string>Claude Code voice mode (hold Space to talk) records from the microphone inside Tabwise's terminals.</string>
  <key>NSAppleEventsUsageDescription</key><string>Tabwise closes the old Terminal windows of sessions you import.</string>
  <key>SUFeedURL</key><string>https://github.com/bulgariamitko/tabwise/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>Bssoy3sPcGjJ4B5GJsbgfv1ylCjUXk/m6cubgoc1Sws=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>14400</integer>
</dict>
</plist>
PLIST

# Local builds: sign with your Apple Development certificate, so macOS keeps permissions such as the
# microphone across rebuilds (an ad-hoc signature changes every build and resets them).
if [ "${SKIP_SIGN:-}" != "1" ]; then
  SIGN_ID="${SIGN_ID:-$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/{print $2; exit}')}"
  codesign --force --deep -s "${SIGN_ID:--}" "$APP"
  echo "Signed with: ${SIGN_ID:-ad-hoc}"
fi
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"

if [ "${1:-}" = "install" ]; then
  rm -rf "/Applications/Tabwise.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Tabwise.app"
fi
