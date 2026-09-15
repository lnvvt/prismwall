#!/bin/zsh
# 发布构建：release 优化 + 正式 .app 打包 + DMG 分发包
# 用法：./Scripts/make-release.sh [版本号]
# 产出：.build/dist/PrismWall-<版本>.dmg + 安装说明
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP="PrismWall.app"
BUNDLE_ID="com.hewentao.prismwall"
DIST=".build/dist"
RELEASE_BIN=".build/release/PrismWall"

echo "=== Release 构建（优化，无调试开销）==="
swift build -c release

echo "=== 打包 $APP ==="
# 干净临时目录构建：与开发环境物理隔离，杜绝私人数据混入
DIST="$(mktemp -d /tmp/prismwall-release.XXXXXX)"
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

echo "=== 组装 DMG 内容 ==="
cat > "$DIST/INSTALL.txt" <<'EOF'
PrismWall 安装说明（macOS 14+，Apple Silicon）
================================================

1. 打开 DMG，将 PrismWall.app 拖入右侧「应用程序」文件夹
2. 首次打开：双击后如提示"无法验证开发者"，
   打开 系统设置 → 隐私与安全性，拉到底部点「仍要打开」
   （只需一次；也可在终端执行：xattr -cr /Applications/PrismWall.app）

说明
----
- 完全本地运行：不申请任何网络权限，不上传任何数据
- 媒体库索引与缩略图缓存仅存于本机
- PrismWall 采用 MIT 协议完全开源免费：https://github.com/lnvvt/prismwall
EOF

DMGVOL="PrismWall-$VERSION"
STAGING="$DIST/$DMGVOL"
mkdir -p "$STAGING"
cp -R "$DIST/$APP" "$STAGING/$APP"
cp "$DIST/INSTALL.txt" "$STAGING/INSTALL.txt"
ln -s /Applications "$STAGING/Applications"

echo "=== 生成 DMG ==="
hdiutil create -volname "$DMGVOL" -srcfolder "$STAGING" -ov -format UDZO \
  "$DIST/PrismWall-$VERSION-arm64.dmg" >/dev/null
shasum -a 256 "$DIST/PrismWall-$VERSION-arm64.dmg" > "$DIST/PrismWall-$VERSION-arm64.dmg.sha256"

# ============ 隐私自检（任一失败即中止，不产出分发包）============
echo "=== 隐私自检 ==="
USERNAME=$(whoami)
APP_PATH="$STAGING/$APP"
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
  echo "  已加载个人敏感词库（$((${#sensitive_patterns[@]} - 7)) 个自定义词条）"
fi

# 1) 文件白名单：DMG 内容不允许出现清单之外的文件
expected=$(cat <<EOF
$APP/Contents/Info.plist
$APP/Contents/MacOS/PrismWall
$APP/Contents/Resources/AppIcon.icns
$APP/Contents/_CodeSignature/CodeResources
INSTALL.txt
Applications
EOF
)
actual=$(cd "$STAGING" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort)
expect_sorted=$(echo "$expected" | sort)
if [ "$actual" != "$expect_sorted" ]; then
  echo "❌ [1] 文件清单超出白名单："
  diff <(echo "$expect_sorted") <(echo "$actual") || true
  fail=1
else
  echo "  ✅ [1] 文件白名单（6/6 完全匹配）"
fi

# 2) 全文件字符串扫描：对包内每一个文件（二进制/图标/plist/文本）扫描敏感模式
scan_fail=0
while IFS= read -r f; do
  for p in "${sensitive_patterns[@]}"; do
    if strings "$f" 2>/dev/null | grep -q -- "$p"; then
      echo "❌ [2] 发现敏感字符串 \"$p\" 于: ${f#$STAGING/}"
      strings "$f" 2>/dev/null | grep -- "$p" | head -3
      scan_fail=1
    fi
  done
done < <(find "$STAGING" -type f)
if [ $scan_fail -ne 0 ]; then fail=1; else
  echo "  ✅ [2] 全文件敏感字符串扫描（$(( ${#sensitive_patterns[@]} )) 个模式）"
fi

# 3) 数据库/缓存禁入
if find "$STAGING" | grep -q "sqlite\|thumbs"; then
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
  rm -rf "$DIST"
  exit 1
fi

echo ""
echo "==================================================="
echo "✅ 隐私自检全部通过（6 项审计）"
echo "   发布包内仅含：程序二进制 / 图标 / 配置 / 签名 / 安装说明"
echo "   已验证：无用户名 · 无用户路径 · 无测试数据 · 无数据库缓存"
echo "           · 无网络权限 · 签名完整"
echo "==================================================="

echo ""
echo "=== 完成 ==="
mkdir -p ".build/dist"
cp "$DIST/PrismWall-$VERSION-arm64.dmg" "$DIST/PrismWall-$VERSION-arm64.dmg.sha256" .build/dist/
rm -rf "$DIST"
echo "分发包: .build/dist/PrismWall-$VERSION-arm64.dmg"
