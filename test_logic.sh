#!/bin/zsh
set -eu
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 5 -module-cache-path build/module-cache Sources/Models.swift Sources/Database.swift Sources/Vendors.swift TestLogic/main.swift -o "$TEST_DIR/test_logic"
AR_DATA_DIR="$TEST_DIR" "$TEST_DIR/test_logic"
