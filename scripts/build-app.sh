#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="$ROOT/dist/留白.app"
mkdir -p "$ROOT/build/arm64" "$ROOT/build/x86_64" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译 Apple Silicon 版本…"
xcrun swiftc -swift-version 5 -parse-as-library -O -whole-module-optimization -module-cache-path "$ROOT/build/ModuleCache" \
    -target arm64-apple-macos13.0 -sdk "$SDK" \
    "$ROOT"/Sources/Liubai/*.swift -o "$ROOT/build/arm64/Liubai"
echo "编译 Intel 版本…"
xcrun swiftc -swift-version 5 -parse-as-library -O -whole-module-optimization -module-cache-path "$ROOT/build/ModuleCache" \
    -target x86_64-apple-macos13.0 -sdk "$SDK" \
    "$ROOT"/Sources/Liubai/*.swift -o "$ROOT/build/x86_64/Liubai"
xcrun lipo -create "$ROOT/build/arm64/Liubai" "$ROOT/build/x86_64/Liubai" -output "$APP/Contents/MacOS/Liubai"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
cp "$ROOT/Resources/zh-Hans.lproj/InfoPlist.strings" "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
xcrun swift -module-cache-path "$ROOT/build/ModuleCache" "$ROOT/scripts/make-icon.swift" "$ROOT/build/AppIcon.iconset"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/留白.zip"
echo "已生成：$APP"
