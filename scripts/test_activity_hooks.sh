#!/bin/bash
# 活动 hook 安装 / 卸载与 hook 脚本回归。只在临时目录里造假的 CLI 配置，不碰真实的 ~/.claude、~/.codex 等。
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yybar-hooks-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -o "$TEST_DIR/regression" Tests/ActivityHooksRegression.swift \
  Core/Usage/ActivityHooks.swift Core/Usage/UsageActivityMonitor.swift Core/Usage/UsageModels.swift
"$TEST_DIR/regression" "$TEST_DIR"
