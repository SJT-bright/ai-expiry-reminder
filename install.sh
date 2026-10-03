#!/bin/zsh
# 受控安装/更新：构建 → 优雅停机 → 备份 → 替换 → 校验 → 重启 → 验收。
# 任何一步失败立即中止（旧行为：pkill -9 宽泛强杀、无备份 rm -rf、codesign 失败被 || true 吞掉）。
# 回滚：BACKUP_DIR 里有 app-old.zip 与 data.sqlite；解包回 /Applications 并放回数据即可。
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/AI到期提醒.app"
BIN="Contents/MacOS/AIReminder"
LABEL="com.sijunting.ai-expiry-reminder"
DATA_DIR="$HOME/Library/Application Support/AI到期提醒"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$HOME/Documents/ai-reminder-backup-$STAMP"

running_pid() { pgrep -x AIReminder | head -1 || true; }

echo "── 1/7 构建"
./build.sh
codesign --verify --deep --strict "build/AI到期提醒.app"
NEW_HASH=$(shasum -a 256 "build/AI到期提醒.app/$BIN" | awk '{print $1}')
echo "构建哈希 sha256=$NEW_HASH"

echo "── 2/7 精确停机（AppleEvent → SIGTERM 升级，绝不强杀）"
OLD_PID=$(running_pid)
[[ "$OLD_PID" =~ ^[0-9]+$ ]] || OLD_PID=""   # 插值进 osascript 前强制数字，杜绝命令注入
if [ -n "$OLD_PID" ]; then
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $OLD_PID) to quit" >/dev/null 2>&1 || true
    for i in {1..10}; do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$OLD_PID" 2>/dev/null; then
        # 实测本应用对 System Events 的 quit AppleEvent 可能静默不理会（rc=0 但不退出），
        # 不能信任其返回码——只要还活着就升级到 SIGTERM（让 applicationWillTerminate 走完）。
        echo "AppleEvent 未生效，改发 SIGTERM…"
        kill -TERM "$OLD_PID" 2>/dev/null || true
        for i in {1..15}; do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.2; done
    fi
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "✗ 旧实例 PID $OLD_PID 未退出，中止安装（绝不 SIGKILL，避免损伤数据库）；请手动退出后重跑"
        exit 1
    fi
    echo "旧实例 PID $OLD_PID 已退出"
fi
launchctl bootout gui/$(id -u)/"$LABEL" 2>/dev/null || true   # 常驻未启用时报错属预期

echo "── 3/7 备份 → $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
[ -d "$APP" ] && ditto -c -k --keepParent "$APP" "$BACKUP_DIR/app-old.zip"
[ -f "$DATA_DIR/data.sqlite" ] && sqlite3 "$DATA_DIR/data.sqlite" ".backup '$BACKUP_DIR/data.sqlite'"
[ -f "$DATA_DIR/state.json" ] && cp "$DATA_DIR/state.json" "$BACKUP_DIR/"
ls -la "$BACKUP_DIR"

echo "── 4/7 替换"
[ -d "$APP" ] && rm -rf "$APP"
ditto "build/AI到期提醒.app" "$APP"

echo "── 5/7 校验安装件"
INSTALLED_HASH=$(shasum -a 256 "$APP/$BIN" | awk '{print $1}')
[ "$INSTALLED_HASH" = "$NEW_HASH" ] || { echo "✗ 安装件哈希与构建不一致（$INSTALLED_HASH），中止"; exit 1; }
codesign --verify --deep --strict "$APP"
echo "安装件哈希一致，签名有效"

echo "── 6/7 重启（常驻开关由应用按用户偏好自行管理）"
open "$APP"
for i in {1..30}; do [ -n "$(running_pid)" ] && break; sleep 0.3; done

echo "── 7/7 验收运行中二进制"
PID=$(running_pid)
if [ -z "$PID" ]; then
    echo "✗ 应用未运行，请手动打开 $APP；备份在 $BACKUP_DIR"
    exit 1
fi
RUN_INODE=$(lsof -p "$PID" 2>/dev/null | awk '$4=="txt" && /Contents\/MacOS\/AIReminder/ {print $8; exit}')
DISK_INODE=$(ls -i "$APP/$BIN" | awk '{print $1}')
if [ -n "$RUN_INODE" ] && [ "$RUN_INODE" = "$DISK_INODE" ]; then
    echo "✓ 已安装：运行中 PID $PID 加载的正是新二进制（inode 一致，sha256=$INSTALLED_HASH）"
else
    echo "⚠ 运行中进程（PID $PID）加载的不是新二进制，请手动退出应用后重开"
fi
if launchctl print gui/$(id -u)/"$LABEL" >/dev/null 2>&1; then
    echo "常驻：已启用"
else
    echo "常驻：未启用（与安装前偏好一致；如需开启请在设置后台勾选）"
fi
echo "回滚：mv $APP /Applications/AI到期提醒-new.bak.app && ditto -x -k $BACKUP_DIR/app-old.zip /Applications/"
