#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build --build-system native -c release --arch arm64
app="$PWD/dist/Pageglass.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/arm64-apple-macosx/release/Pageglass "$app/Contents/MacOS/Pageglass"
cp -R .build/arm64-apple-macosx/release/Pageglass_Browser.bundle "$app/Contents/Resources/"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.pageglass.browser</string>
<key>CFBundleName</key><string>Pageglass</string>
<key>CFBundleDisplayName</key><string>Pageglass</string>
<key>CFBundleExecutable</key><string>Pageglass</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
<key>NSCameraUsageDescription</key><string>仅在你允许网站使用摄像头时访问。</string>
<key>NSMicrophoneUsageDescription</key><string>仅在你允许网站使用麦克风时访问。</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
print "$app"
