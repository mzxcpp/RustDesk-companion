#!/bin/zsh
# 构建「RustDesk Companion.app」（中文系统显示为「RustDesk 伴侣」）
# 用法：scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
APP_NAME="RustDesk Companion"
APP="build/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ "$SIGN_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
  echo "❌ 钥匙串中找不到有效的代码签名证书「$SIGN_IDENTITY」；没有证书可用 SIGN_IDENTITY=- 改为 ad-hoc 签名" >&2
  exit 1
fi

swift build -c release --product RustDisplay
BIN="$(swift build -c release --show-bin-path)/RustDisplay"
BIN_DIR="$(dirname "$BIN")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RustDisplay"
# 看门狗用独立文件名，避免 pkill RustDisplay 时连同看门狗一起结束
cp "$BIN" "$APP/Contents/MacOS/RustDisplayWatchdog"

# 复制依赖可能产生的资源包（如存在）
for bundle in "$BIN_DIR"/*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# 功能导览配图与 App 图标、菜单栏模板图
cp Assets/Tour/*.png "$APP/Contents/Resources/"
cp Assets/AppIcon/AppIcon.icns Assets/AppIcon/MenuBarIconTemplate.png Assets/AppIcon/MenuBarIconTemplate@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.rustcomp.rustdisplay</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
  <key>CFBundleName</key><string>RustDesk Companion</string>
  <key>CFBundleDisplayName</key><string>RustDesk Companion</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleExecutable</key><string>RustDisplay</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

mkdir -p "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"
printf '"CFBundleDisplayName" = "RustDesk 伴侣";\n"CFBundleName" = "RustDesk 伴侣";\n' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
printf '"CFBundleDisplayName" = "RustDesk Companion";\n"CFBundleName" = "RustDesk Companion";\n' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"

codesign --force --sign "$SIGN_IDENTITY" --identifier com.rustcomp.rustdisplay.watchdog "$APP/Contents/MacOS/RustDisplayWatchdog"
codesign --force --sign "$SIGN_IDENTITY" --identifier com.rustcomp.rustdisplay "$APP"
codesign --verify --strict --deep "$APP"
echo "✅ 已生成 $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x RustDisplay 2>/dev/null && sleep 1 || true
  pkill -x RustDisplayWatchdog 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "✅ 已安装到 /Applications 并启动"
fi
