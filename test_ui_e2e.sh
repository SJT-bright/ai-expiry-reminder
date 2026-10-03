#!/bin/zsh
# 构建供桌面自动化工具操作的隔离验收 App；此脚本自身不声称 E2E 通过。
set -eu
cd "$(dirname "$0")"
APP="build/AI到期提醒验收.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sijunting.ai-expiry-reminder.ui-acceptance</string>
<key>CFBundleName</key><string>AI到期提醒验收</string>
<key>CFBundleExecutable</key><string>UIAcceptance</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
swiftc -Onone -swift-version 5 -target "$(uname -m)-apple-macos26.0" -module-cache-path build/module-cache \
 Sources/Models.swift Sources/Database.swift Sources/Resident.swift Sources/Readers.swift Sources/Motion.swift \
 Sources/Vendors.swift Sources/CalendarPicker.swift Sources/PanelUI.swift Sources/Settings.swift \
 TestE2E/main.swift -o "$APP/Contents/MacOS/UIAcceptance"
codesign --force --deep --sign - "$APP"
echo "隔离验收入口：$APP（请用原生桌面 E2E 工具实际操作；完成后关闭并清理 build/ui-acceptance-data）"
