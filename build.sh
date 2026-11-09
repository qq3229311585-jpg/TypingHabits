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
KC="$HOME/Library/Keychains/typinghabits-dev.keychain-db"
if security find-identity "$KC" 2>/dev/null | grep -q "TypingHabits Local Dev"; then
  security unlock-keychain -p "" "$KC"
  codesign --force --keychain "$KC" -s "TypingHabits Local Dev" $APP
  echo "已用固定签名(重装不需要重新授权)"
else
  codesign --force -s - $APP
  echo "临时签名:先运行 ./setup_signing.sh 可避免每次重装都要重新授权"
fi
echo built $APP
