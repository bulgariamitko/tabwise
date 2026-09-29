#!/bin/bash
# Builds a public release of Tabwise:
#   universal app → Developer ID signature (hardened runtime) → notarized + stapled → .dmg (also
#   notarized + stapled) → Sparkle signature → appcast.xml.   `./release.sh --publish` also creates
#   the GitHub release (tag v<VERSION>) with the .dmg and appcast.xml.
#
# One-time setup — notarization credentials, either:
#   a) App Store Connect API key:  export NOTARY_KEY_ID=… NOTARY_ISSUER=…   (key file in ~/.appstoreconnect/private_keys)
#   b) Keychain profile:           xcrun notarytool store-credentials tabwise-notary --apple-id … --team-id …
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
REPO="bulgariamitko/tabwise"
# Assembled outside Dropbox: its extended attributes break code signing, and DMGs shouldn't sync.
OUT="$HOME/Library/Caches/Tabwise-build/release/$VERSION"
APP="$OUT/Tabwise.app"
DMG="$OUT/Tabwise-$VERSION.dmg"
SPARKLE_BIN="$HOME/Library/Caches/Tabwise-build/artifacts/sparkle/Sparkle/bin"
ID="${DEVELOPER_ID:-$(security find-identity -p codesigning -v | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -n "$ID" ] || { echo "No 'Developer ID Application' certificate in the Keychain."; exit 1; }

notarize() {
  if [ -n "${NOTARY_KEY_ID:-}" ]; then
    local key="${NOTARY_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${NOTARY_KEY_ID}.p8}"
    xcrun notarytool submit "$1" --key "$key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  else
    xcrun notarytool submit "$1" --keychain-profile "${NOTARY_PROFILE:-tabwise-notary}" --wait
  fi
}

echo "▸ Building universal app $VERSION"
UNIVERSAL=1 SKIP_SIGN=1 BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}" ./build.sh
rm -rf "$OUT" && mkdir -p "$OUT"
ditto --noextattr --norsrc build.noindex/Tabwise.app "$APP"
xattr -cr "$APP"

echo "▸ Signing with $ID (hardened runtime)"
sign() { codesign --force --timestamp --options runtime --sign "$ID" "$@"; }
FW="$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle's helpers are signed inside-out, as its documentation describes.
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign --entitlements Tabwise.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▸ Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/Tabwise-notarize.zip"
notarize "$OUT/Tabwise-notarize.zip"
xcrun stapler staple "$APP"
rm "$OUT/Tabwise-notarize.zip"

echo "▸ Building $DMG"
STAGE="$OUT/dmg" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Tabwise.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tabwise $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$ID" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "▸ Sparkle appcast"
SIG="$("$SPARKLE_BIN/sign_update" --account tabwise "$DMG")"   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/v$VERSION/Tabwise-$VERSION.dmg"
NOTES="$(awk -v v="## $VERSION" '$0==v{f=1;next} /^## /{f=0} f' CHANGELOG.md | sed 's/&/\&amp;/g; s/</\&lt;/g')"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tabwise</title>
    <item>
      <title>Tabwise $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$(defaults read "$APP/Contents/Info" CFBundleVersion)</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<pre>$NOTES</pre>]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
echo "✓ $DMG and $OUT/appcast.xml are ready"

if [ "${1:-}" = "--publish" ]; then
  echo "▸ Publishing GitHub release v$VERSION"
  gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --title "Tabwise $VERSION" \
    --notes "$(awk -v v="## $VERSION" '$0==v{f=1;next} /^## /{f=0} f' CHANGELOG.md)"
fi
