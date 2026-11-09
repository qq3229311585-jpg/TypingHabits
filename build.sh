#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=TypingHabits.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp AppIcon.icns $APP/Contents/Resources/
swiftc -swift-version 5 -O -parse-as-library main.swift -o $APP/Contents/MacOS/TypingHabits
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>LSUIElement</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>TypingHabits</string>
<key>CFBundleExecutable</key><string>TypingHabits</string>
<key>CFBundleIdentifier</key><string>local.typinghabits</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PL
codesign --force -s - $APP
echo built $APP
