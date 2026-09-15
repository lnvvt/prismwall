#!/bin/zsh
# 从 SwiftPM 构建产物打包最小 .app 并注入沙盒 entitlements（S4 spike 用）
set -e
cd "$(dirname "$0")/.."

APP=".build/PrismWallSandbox.app"
BIN="$APP/Contents/MacOS/PrismWallSandbox"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp .build/icon/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
cp .build/debug/PrismWall "$BIN"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.hewentao.prismwall.sandbox</string>
    <key>CFBundleExecutable</key>
    <string>PrismWallSandbox</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>PrismWallSandbox</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
EOF

codesign --force --sign - --entitlements Scripts/sandbox-dev.entitlements "$APP"
echo "signed: $APP"
codesign -d --entitlements - "$APP" 2>&1 | tail -7
