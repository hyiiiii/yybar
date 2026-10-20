#!/bin/bash
# agy 会话库用量解析回归。样例库现场合成，不读真实会话、不运行 agy。
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yybar-agy-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -o "$TEST_DIR/regression" Tests/AgyConversationRegression.swift \
  Core/Usage/AgyConversationScanner.swift Core/Usage/UsageModels.swift Core/Usage/Pricing.swift \
  Core/Storage/ScanCache.swift Core/Usage/CodexJSONLScanner.swift Core/Usage/JSONLLineReader.swift
"$TEST_DIR/regression" "$@"
