#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Keep the native build system although Swift 6.4 marks it deprecated: the default (swiftbuild) build
# records the deployment target as the SDK version (sdk 14.0), so AppKit applies old-SDK behavior and
# smoke fails (a tab-row scroller takes tab clicks). Revisit before native is removed; check
# `otool -l … | grep -A5 LC_BUILD_VERSION` reports the installed SDK.
swift build --build-system native -c release --arch arm64
bin=$(swift build --build-system native -c release --arch arm64 --show-bin-path)
app="$PWD/dist/Pageglass.app"
rm -rf "$app/Contents/Resources/Pageglass_Browser.bundle"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Pageglass" "$app/Contents/MacOS/Pageglass"
cp -R "$bin/Pageglass_Browser.bundle" "$app/Contents/Resources/"
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
<key>CFBundleShortVersionString</key><string>0.10.0-alpha.1</string>
<key>CFBundleVersion</key><string>36</string>
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
