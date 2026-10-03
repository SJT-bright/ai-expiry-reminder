#!/bin/zsh
# 人工填表模拟：经真实表单路径添加 14 个基于真实供应商规则的场景，核对排期/建议/窗口生成。
# 数据写入隔离临时目录，渲染 build/render/manual_*.png 供人工检查。
# 退出码：0=全部符合预期 / 1=有 FAIL / 2=未提供隔离数据目录 / 3=链路超时挂死。
set -eu
cd "$(dirname "$0")"
mkdir -p build/render
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 5 -module-cache-path build/module-cache \
    Sources/Models.swift Sources/Database.swift Sources/Resident.swift Sources/Readers.swift Sources/Motion.swift Sources/Vendors.swift Sources/CalendarPicker.swift Sources/PanelUI.swift Sources/Settings.swift \
    TestManual/main.swift -o "$TEST_DIR/manual_test"
rc=0
AR_DATA_DIR="$TEST_DIR" "$TEST_DIR/manual_test" || rc=$?
if (( rc != 0 )); then
    echo "✗ 人工场景测试未通过（退出码 $rc）——失败清单见上方 FAILURES，渲染产物在 build/render/manual_*.png" >&2
    exit "$rc"
fi
echo "完成 → build/render/manual_*.png"
