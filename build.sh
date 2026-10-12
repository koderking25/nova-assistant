#!/bin/zsh
# Builds Nova.app (for Apple silicon and Intel Macs, macOS 13 or later) and the download for the website.
# Run:  ./build.sh
set -e
cd "$(dirname "$0")"
version="1.0.0"
work="$(mktemp -d)"
app="dist/Nova.app"
rm -rf dist && mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

echo "Building the engine…"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 src/*.swift -o "$work/engine-$arch" 2> "$work/engine-$arch.log" || { grep error -A4 "$work/engine-$arch.log" | head -20; exit 1; }
done
lipo -create "$work/engine-arm64" "$work/engine-x86_64" -output "$app/Contents/Resources/nova-engine"

echo "Building the window…"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 -parse-as-library src/ui/NovaUI.swift -o "$work/ui-$arch" 2> "$work/ui-$arch.log" || { grep error -A4 "$work/ui-$arch.log" | head -20; exit 1; }
done
lipo -create "$work/ui-arm64" "$work/ui-x86_64" -output "$app/Contents/MacOS/Nova"

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

cp src/reaper/talking_piano_bridge.lua "$app/Contents/Resources/"
cp src/kokoro_server.py "$app/Contents/Resources/"
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
codesign --force --deep --sign - "$app" >/dev/null 2>&1
rm -f site/Nova.zip
ditto -c -k --keepParent "$app" site/Nova.zip
rm -rf "$work"
echo "Built $app  ($(du -sh "$app" | cut -f1)) and site/Nova.zip ($(du -sh site/Nova.zip | cut -f1))"
