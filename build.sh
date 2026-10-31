#!/bin/zsh
set -euo pipefail

dir="${0:A:h}"
build="$dir/build"
app="$build/Stillwake.app"
version="$(<"$dir/VERSION")"
bundle_id="io.github.pjotreek.stillwake"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" \
        "$dir"/Sources/*.swift \
        -o "$build/Stillwake-$arch" \
        -framework AppKit -framework IOKit -framework ScreenCaptureKit -framework ServiceManagement -framework QuartzCore -framework CoreImage -framework Metal -framework MetalPerformanceShaders
done
lipo -create "$build/Stillwake-arm64" "$build/Stillwake-x86_64" -output "$app/Contents/MacOS/Stillwake"
rm -f "$build/Stillwake-arm64" "$build/Stillwake-x86_64"

[[ -f "$dir/Resources/AppIcon.icns" ]] && cp "$dir/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$dir/THIRD_PARTY_NOTICES.txt" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleName</key>
    <string>Stillwake</string>
    <key>CFBundleDisplayName</key>
    <string>Stillwake</string>
    <key>CFBundleExecutable</key>
    <string>Stillwake</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier "$bundle_id" -r="designated => identifier \"$bundle_id\"" "$app"
echo "$app"
