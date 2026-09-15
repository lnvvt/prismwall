#!/bin/zsh
# 从 SwiftPM 构建产物打包开发版 .app（非沙盒、ad-hoc 签名）
# 用于日常运行与 GUI 自动化验证（裸可执行文件无 bundle 身份，无法被自动化工具驱动）
set -e
cd "$(dirname "$0")/.."

swift build
APP=".build/PrismWallDev.app"
BIN="$APP/Contents/MacOS/PrismWall"

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
    <string>com.hewentao.prismwall</string>
    <key>CFBundleExecutable</key>
    <string>PrismWall</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>PrismWall</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>浏览你选择的本地媒体文件夹</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "built: $APP"
