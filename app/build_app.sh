#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Completionist's Guide"
BUNDLE_DIR="$DIR/$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "=== Building $APP_NAME.app ==="

# 1. Clean previous build
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 2. Compile Swift binary
echo "Compiling Swift executable..."
swiftc -O -target arm64-apple-macos14.0 -framework Cocoa -framework AppKit "$DIR/main.swift" -o "$MACOS_DIR/$APP_NAME"

# 3. Generate icon if not present
if [ ! -f "$DIR/AppIcon.icns" ]; then
    echo "Generating AppIcon.icns..."
    python3 "$DIR/make_icon.py" "$DIR/AppIcon.icns"
fi
cp "$DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# 4. Create Info.plist
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Completionist's Guide</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>org.batesai.CompletionistsGuide</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Completionist's Guide</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Daniel Bates / Bates LLC. All rights reserved.</string>
</dict>
</plist>
EOF

echo "App bundle built at: $BUNDLE_DIR"

# 5. Install to /Applications
DEST="/Applications/$APP_NAME.app"
echo "Installing to $DEST..."
rm -rf "$DEST"
cp -R "$BUNDLE_DIR" "$DEST"
echo "Successfully installed $APP_NAME to $DEST"
