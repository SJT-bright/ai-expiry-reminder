#!/bin/zsh
# 离屏渲染自测：生成悬浮窗（展开/收起）、设置后台、添加表单的 PNG
set -e
cd "$(dirname "$0")"
mkdir -p build/render
rm -rf /tmp/ar_test_data

swiftc -O -swift-version 5 \
    Sources/Models.swift Sources/Database.swift Sources/Resident.swift Sources/Readers.swift Sources/Notifier.swift Sources/PanelUI.swift Sources/Settings.swift \
    TestRender/main.swift -o build/render_test 2>&1 | grep -E "error" && exit 1 || true

BIN="/tmp/rt_bin_$(date +%s)"      # 唯一路径，避开被污染的 LaunchServices 注册
cp build/render_test "$BIN"
AR_DATA_DIR=/tmp/ar_test_data "$BIN"
echo "完成 → build/render/*.png"
