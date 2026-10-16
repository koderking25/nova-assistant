#!/bin/zsh
# Builds Nova for Apple silicon and Intel Macs (macOS 13 or later), and everything the website serves:
#   dist/Nova.app       the app
#   site/Nova.dmg       the download: a disk image with a drag-to-Applications window
#   site/payload.zip    what an installed Nova fetches to update itself
#   site/version.json   what an installed Nova reads to learn there is an update
#
# To release an update: raise "version", say what is new in "notes", run ./build.sh, then deploy the site.
set -e
cd "$(dirname "$0")"
version="1.4.0"
notes="A brain of my own that works on any Mac with no internet, a natural voice that installs in one step and starts in a second, no more little sound effects, smoother animation, and goon mode."

work="$(mktemp -d)"
app="dist/Nova.app"
payload="$app/Contents/Resources/payload"
rm -rf dist && mkdir -p "$app/Contents/MacOS" "$payload"
print "// Written by build.sh. The version of this build.\nlet novaVersion = \"$version\"" > src/version.swift

echo "Building the engine…"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 -import-objc-header src/sherpa/c-api.h src/*.swift -o "$work/engine-$arch" 2> "$work/engine-$arch.log" || { grep error -A4 "$work/engine-$arch.log" | head -20; exit 1; }
done
lipo -create "$work/engine-arm64" "$work/engine-x86_64" -output "$payload/nova-engine"

echo "Building the window…"
# The macOS 27 command line tools need Xcode's SwiftUI macro plugin, which they do not include.
# Where the macOS 26 SDK is also installed, the window is built against that one, which needs no plugin.
uisdk="$(xcrun --show-sdk-path)"
[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ] && [ ! -d "$(xcode-select -p)/Platforms" ] && uisdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
for arch in arm64 x86_64; do
  SDKROOT="$uisdk" swiftc -O -swift-version 5 -target $arch-apple-macos13.0 -parse-as-library -emit-library src/ui/NovaUI.swift -o "$work/ui-$arch.dylib" 2> "$work/ui-$arch.log" || { grep error -A4 "$work/ui-$arch.log" | head -20; exit 1; }
done
lipo -create "$work/ui-arm64.dylib" "$work/ui-x86_64.dylib" -output "$payload/libNovaUI.dylib"

echo "Building the starter…"
clang -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 src/ui/host.c -o "$app/Contents/MacOS/Nova"

cp src/reaper/talking_piano_bridge.lua src/kokoro_server.py "$payload/"
print -n "$version" > "$payload/version.txt"

echo "Drawing the icon…"
swiftc -O src/ui/make_icon.swift -o "$work/make_icon" 2>/dev/null
"$work/make_icon" "$work/icon.png"
mkdir "$work/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$work/icon.png" --out "$work/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$work/icon.png" --out "$work/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
mkdir -p site/assets && sips -z 256 256 "$work/icon.png" --out site/assets/icon.png >/dev/null

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Nova</string>
<key>CFBundleDisplayName</key><string>Nova</string>
<key>CFBundleIdentifier</key><string>app.nova.assistant</string>
<key>CFBundleExecutable</key><string>Nova</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSMicrophoneUsageDescription</key><string>Nova listens for its name so you can ask for things by voice. The listening happens on this Mac.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Nova turns what you say after its name into requests, on this Mac.</string>
<key>NSAppleEventsUsageDescription</key><string>Nova uses this to carry out what you ask for in other apps, such as playing a song in Spotify.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Signing. With an Apple Developer ID (set NOVA_SIGN to its name, for example
#   export NOVA_SIGN="Developer ID Application: Your Name (TEAMID)"
# and NOVA_NOTARY to a notarytool keychain profile), the app is signed properly, sent to Apple to be
# checked, and stamped, so nobody is warned when they open it. Without one it is signed "ad hoc".
if [[ -n "$NOVA_SIGN" ]]; then
  cat > "$work/entitlements.plist" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
ENT
  # Everything is signed by the same developer, so the starter may load the window's code from the Library.
  codesign --force --options runtime --timestamp --sign "$NOVA_SIGN" "$payload/libNovaUI.dylib"
  codesign --force --options runtime --timestamp --entitlements "$work/entitlements.plist" --sign "$NOVA_SIGN" "$payload/nova-engine"
  codesign --force --options runtime --timestamp --entitlements "$work/entitlements.plist" --sign "$NOVA_SIGN" "$app"
else
  codesign --force --deep --sign - "$app" >/dev/null 2>&1
fi

# The download: a disk image whose window shows the app, an arrow, and the Applications folder.
echo "Making the disk image…"
swiftc -O src/ui/make_dmg_background.swift -o "$work/make_bg" 2>/dev/null
stage="$work/stage"; mkdir -p "$stage/.background"
"$work/make_bg" "$stage/.background/background.png"
ditto "$app" "$stage/Nova.app"
ln -s /Applications "$stage/Applications"
rm -f "$work/rw.dmg" site/Nova.dmg site/Nova.zip
hdiutil create -quiet -volname "Nova" -srcfolder "$stage" -fs HFS+ -format UDRW -size 60m "$work/rw.dmg"
mount=$(hdiutil attach -readwrite -noverify -noautoopen "$work/rw.dmg" | grep -o '/Volumes/.*' | head -1)
osascript <<OSA >/dev/null 2>&1 || echo "  (the window layout could not be set; the image still works)"
tell application "Finder"
  tell disk "Nova"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 140, 860, 588}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 14
    set background picture of opts to file ".background:background.png"
    set position of item "Nova.app" of container window to {170, 218}
    set position of item "Applications" of container window to {490, 218}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync; hdiutil detach -quiet "$mount" || hdiutil detach -quiet -force "$mount"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o site/Nova.dmg
if [[ -n "$NOVA_SIGN" ]]; then
  codesign --force --timestamp --sign "$NOVA_SIGN" site/Nova.dmg
  if [[ -n "$NOVA_NOTARY" ]]; then
    echo "Sending to Apple to be checked (this takes a few minutes)…"
    xcrun notarytool submit site/Nova.dmg --keychain-profile "$NOVA_NOTARY" --wait
    xcrun stapler staple site/Nova.dmg
  fi
fi

# What an installed Nova fetches to update itself.
rm -f site/payload.zip
ditto -c -k "$payload" site/payload.zip
sum=$(shasum -a 256 site/payload.zip | cut -d' ' -f1)
cat > site/version.json <<JSON
{
  "version": "$version",
  "notes": "$notes",
  "url": "https://saynova.app/payload.zip",
  "sha256": "$sum"
}
JSON
rm -rf "$work"
echo "Built Nova $version: $app ($(du -sh "$app" | cut -f1)), site/Nova.dmg ($(du -sh site/Nova.dmg | cut -f1)), site/payload.zip ($(du -sh site/payload.zip | cut -f1))"
