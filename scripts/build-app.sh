#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift build -c release
app="$PWD/dist/Connect My World in Herdr.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/ConnectMyWorld "$app/Contents/MacOS/ConnectMyWorld"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.justn.connect-my-world-in-herdr</string>
<key>CFBundleName</key><string>Connect My World in Herdr</string>
<key>CFBundleExecutable</key><string>ConnectMyWorld</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleShortVersionString</key><string>0.1.3</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
print -r -- "$app"
