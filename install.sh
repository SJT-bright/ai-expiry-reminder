#!/bin/zsh
# 一键安装/更新：构建 → 安装到 /Applications → 启动（常驻自动指向新位置）
set -e
cd "$(dirname "$0")"

./build.sh

# 结束旧实例
pkill -9 -f AIReminder 2>/dev/null || true
sleep 1

# 安装到 /Applications（覆盖旧版本，数据在 ~/Library/Application Support，不受影响）
rm -rf "/Applications/AI到期提醒.app"
cp -R "build/AI到期提醒.app" /Applications/
open "/Applications/AI到期提醒.app"

sleep 3
echo "已安装：/Applications/AI到期提醒.app"
echo "常驻状态：$(launchctl print gui/$(id -u)/com.sijunting.ai-expiry-reminder 2>/dev/null | grep -m1 'program =' || echo '下次启动时自动注册')"
