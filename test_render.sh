#!/bin/zsh
# 隔离数据，编译失败即停止；只渲染演示条目。
set -eu
cd "$(dirname "$0")"
mkdir -p build/render
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -O -swift-version 5 -module-cache-path build/module-cache \
    Sources/Models.swift Sources/Database.swift Sources/Resident.swift Sources/Readers.swift Sources/Notifier.swift Sources/Motion.swift Sources/Vendors.swift Sources/PanelUI.swift Sources/Settings.swift \
    TestRender/main.swift -o "$TEST_DIR/render_test"
AR_DATA_DIR="$TEST_DIR" "$TEST_DIR/render_test"
echo "完成 → build/render/*.png"
