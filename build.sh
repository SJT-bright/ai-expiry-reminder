#!/bin/zsh
# 编译并打包 AI到期提醒.app —— 原生 Swift，产物约 1MB，无任何运行时依赖
set -e
cd "$(dirname "$0")"

APP_NAME="AI到期提醒"
BUNDLE_ID="com.sijunting.ai-expiry-reminder"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# App 图标（缺失时用生成器现场画一个）
if [ ! -f Assets/AppIcon.icns ]; then
    echo "==> 生成 App 图标…"
    swift Assets/make_icon.swift build/AppIcon.iconset >/dev/null
    iconutil -c icns build/AppIcon.iconset -o Assets/AppIcon.icns
fi
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AIReminder</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1.1.2</string>
    <key>CFBundleShortVersionString</key><string>1.1.2</string>
    <key>CFBundleExecutable</key><string>AIReminder</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHumanReadableCopyright</key><string>Personal tool</string>
</dict>
</plist>
PLIST

echo "==> swiftc 编译中…"
# 系统液态玻璃（NSGlassEffectView / NSBezelStyleGlass）是 macOS 26 的公开 API，
# 编译下限就定在 26.0，不再保留磨砂玻璃退路。
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos26.0" -module-cache-path "$BUILD_DIR/module-cache" \
    Sources/Models.swift Sources/Database.swift Sources/Readers.swift Sources/Motion.swift Sources/Vendors.swift Sources/CalendarPicker.swift Sources/PanelUI.swift Sources/Settings.swift Sources/Resident.swift Sources/main.swift \
    -o "$APP/Contents/MacOS/AIReminder"

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> 完成：$APP ($(du -sh "$APP" | cut -f1))"
