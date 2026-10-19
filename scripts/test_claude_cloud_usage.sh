#!/bin/bash
# Isolated synthetic fixtures; never reads credentials or sends network requests.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yybar-cloud-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -o "$TEST_DIR/regression" Tests/ClaudeCloudUsageRegression.swift \
  Core/Usage/ClaudeCloudUsage.swift Core/Usage/ClaudeJSONLScanner.swift \
  Core/Usage/UsageModels.swift Core/Usage/Pricing.swift \
  Core/Usage/JSONLLineReader.swift Core/Storage/ScanCache.swift
"$TEST_DIR/regression" "$@"
