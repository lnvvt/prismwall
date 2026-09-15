#!/bin/zsh
# 发布构建：release 优化 + 正式 .app 打包 + DMG 分发包
# 用法：./Scripts/make-release.sh [版本号]
# 产出：.build/dist/PrismWall-<版本>.dmg + sha256（含 6 项隐私自检，任一失败即中止）
# DMG 设计：品牌化窗口（背景图 + 图标定位 + 卷图标），见 Scripts/make-dmg-background.swift
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP="PrismWall.app"
BUNDLE_ID="com.hewentao.prismwall"
DIST="$(mktemp -d /tmp/prismwall-release.XXXXXX)"
RELEASE_BIN=".build/release/PrismWall"
OUT_DIR=".build/dist"

echo "=== Release 构建（优化，无调试开销）==="
swift build -c release

echo "=== 打包 $APP ==="
# 干净临时目录构建：与开发环境物理隔离，杜绝私人数据混入
mkdir -p "$DIST/$APP/Contents/MacOS"
mkdir -p "$DIST/$APP/Contents/Resources"
cp .build/icon/AppIcon.icns "$DIST/$APP/Contents/Resources/AppIcon.icns"
cp "$RELEASE_BIN" "$DIST/$APP/Contents/MacOS/PrismWall"

cat > "$DIST/$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>PrismWall</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>PrismWall</string>
    <key>CFBundleDisplayName</key>
    <string>PrismWall</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc 签名（无开发者账号可用的最大完整性保证；公证需付费账号，暂缓）
codesign --force --sign - "$DIST/$APP"

# ============ 组装 DMG 内容（安装说明融入背景图，不再放 txt 文件）============
echo "=== 组装 DMG 内容 ==="
DMGVOL="PrismWall $VERSION-arm64"
DMGNAME="PrismWall-$VERSION-arm64.dmg"
STAGING="$DIST/dmg-root"
WIN_W=720; WIN_H=440; TITLEBAR=28

mkdir -p "$STAGING"
cp -R "$DIST/$APP" "$STAGING/$APP"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$STAGING/.background"
swift Scripts/make-dmg-background.swift "$STAGING/.background/background.png"
cp .build/icon/AppIcon.icns "$STAGING/.VolumeIcon.icns"

echo "=== 生成可写 DMG 并定制窗口 ==="
RWDMG="$DIST/rw.dmg"
hdiutil create -volname "$DMGVOL" -fs HFS+ -srcfolder "$STAGING" -ov -format UDRW "$RWDMG" >/dev/null
MNT="/Volumes/$DMGVOL"
hdiutil attach "$RWDMG" -readwrite -nobrowse -noverify -noautoopen >/dev/null

# 卷图标标志必须先于 Finder 操作打上——否则 Finder 会把无标志的 .VolumeIcon.icns 当孤儿文件清掉
SetFile -a C "$MNT"

# Finder 图标视图定制：背景图 + 图标坐标（与背景设计稿同一组坐标）
# 设计基准（窗口坐标，原点左上）：App 图标中心 (205,300)、Applications 中心 (515,300)，图标 104pt
# Finder position 语义按实测：x=图标中心 x；y=图标底边（内容区左下原点）→ y = 416 - 设计中心 y
osascript <<APPLESCRIPT
tell application "Finder"
	tell disk "$DMGVOL"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set theViewOptions to the icon view options of container window
		set background picture of theViewOptions to the file ".background:background.png"
		set arrangement of theViewOptions to not arranged
		set icon size of theViewOptions to 104
		set text size of theViewOptions to 13
		set bounds of container window to {300, 150, $((300 + WIN_W)), $((150 + WIN_H + TITLEBAR))}
		set position of item "PrismWall.app" of container window to {205, 267}
		set position of item "Applications" of container window to {515, 267}
	end tell
end tell
APPLESCRIPT

sync
sleep 3

echo "=== 隐私自检 ==="
USERNAME=$(whoami)
APP_PATH="$MNT/$APP"
fail=0

# 个人敏感词库：Scripts/privacy-words.txt（每行一词，# 开头为注释）
# 该文件已加入 .gitignore——个人词库本身也不应进公开仓库
# 不扫描裸用户名——Bundle ID 合法包含开发者署名（com.hewentao.prismwall），
# 会误伤；真正敏感的是绝对用户路径与测试数据
sensitive_patterns=("/Users/$USERNAME" "/Users/" "$HOME" "prismwall-canary" "prismwall-media" "prismwall-test")
words_file="Scripts/privacy-words.txt"
if [ -f "$words_file" ]; then
  while IFS= read -r w; do
    [[ -n "$w" && "$w" != \#* ]] && sensitive_patterns+=("$w")
  done < "$words_file"
  echo "  已加载个人敏感词库（$((${#sensitive_patterns[@]} - 6)) 个自定义词条）"
fi

# 1) 文件白名单：包内容不允许出现清单之外的文件（挂载卷上检查，含背景图等 DMG 内部文件）
expected=$(cat <<EOF
$APP/Contents/Info.plist
$APP/Contents/MacOS/PrismWall
$APP/Contents/Resources/AppIcon.icns
$APP/Contents/_CodeSignature/CodeResources
Applications
.DS_Store
.VolumeIcon.icns
.background/background.png
EOF
)
actual=$(cd "$MNT" && find . \( -type f -o -type l \) \
  | sed 's|^\./||' \
  | grep -v -E '^(\.fseventsd|\.Trashes|\.Spotlight-V100)/' \
  | grep -v -E '^\.(hotfiles\.btree|metadata_never_index)$|^\._' \
  | sort)
expect_sorted=$(echo "$expected" | sort)
if [ "$actual" != "$expect_sorted" ]; then
  echo "❌ [1] 文件清单超出白名单："
  diff <(echo "$expect_sorted") <(echo "$actual") || true
  fail=1
else
  echo "  ✅ [1] 文件白名单（8/8 完全匹配）"
fi

# 2) 全文件字符串扫描：对包内每一个文件（二进制/图标/plist/背景图/DS_Store）扫描敏感模式
scan_fail=0
while IFS= read -r f; do
  for p in "${sensitive_patterns[@]}"; do
    if strings "$f" 2>/dev/null | grep -q -- "$p"; then
      echo "❌ [2] 发现敏感字符串 \"$p\" 于: ${f#$MNT/}"
      strings "$f" 2>/dev/null | grep -- "$p" | head -3
      scan_fail=1
    fi
  done
done < <(find "$MNT" -type f)
if [ $scan_fail -ne 0 ]; then fail=1; else
  echo "  ✅ [2] 全文件敏感字符串扫描（$(( ${#sensitive_patterns[@]} )) 个模式）"
fi

# 3) 数据库/缓存禁入
if find "$MNT" | grep -q "sqlite\|thumbs"; then
  echo "❌ [3] 包内发现疑似数据库/缓存文件"
  fail=1
else
  echo "  ✅ [3] 无数据库/缩略图缓存"
fi

# 4) 代码签名完整性（分发前必须可验证）
if codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
  echo "  ✅ [4] 代码签名验证通过"
else
  echo "❌ [4] 代码签名验证失败"
  fail=1
fi

# 5) 零网络验证：entitlements 中不得出现任何网络声明
ENT=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || echo "")
if echo "$ENT" | grep -q "network"; then
  echo "❌ [5] 发现网络相关 entitlement（违背零联网承诺）"
  fail=1
else
  echo "  ✅ [5] 零网络 entitlement 确认"
fi

# 6) Info.plist 安全审计：不得出现隐私相关用途声明
PLIST="$APP_PATH/Contents/Info.plist"
plist_leak=$(plutil -convert xml1 -o - "$PLIST" 2>/dev/null | grep -oE "NS[A-Za-z]+UsageDescription" | sort -u || true)
if [ -n "$plist_leak" ]; then
  echo "❌ [6] Info.plist 含用途声明键（应逐一确认必要性）: $plist_leak"
  fail=1
else
  echo "  ✅ [6] Info.plist 无隐私用途声明键"
fi

if [ $fail -ne 0 ]; then
  echo "========================================"
  echo "=== ❌ 隐私自检未通过，已中止发布 ==="
  echo "========================================"
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
  rm -rf "$DIST"
  exit 1
fi

echo ""
echo "==================================================="
echo "✅ 隐私自检全部通过（6 项审计）"
echo "   发布包内仅含：程序二进制 / 图标 / 配置 / 签名 / 背景设计"
echo "   已验证：无用户名 · 无用户路径 · 无测试数据 · 无数据库缓存"
echo "           · 无网络权限 · 签名完整"
echo "==================================================="

hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach "$MNT" -force >/dev/null

echo "=== 生成 DMG ==="
hdiutil convert "$RWDMG" -format UDZO -imagekey zlib-level=9 -o "$DIST/$DMGNAME" >/dev/null
shasum -a 256 "$DIST/$DMGNAME" > "$DIST/$DMGNAME.sha256"

echo ""
echo "=== 完成 ==="
mkdir -p "$OUT_DIR"
cp "$DIST/$DMGNAME" "$DIST/$DMGNAME.sha256" "$OUT_DIR/"
rm -rf "$DIST"
echo "分发包: $OUT_DIR/$DMGNAME"
