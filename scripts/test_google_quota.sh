#!/bin/bash
# Gemini / agy / Grok Bot 额度解析与 Grok Bot 登录解密回归。只用内置样例，不读凭据和钥匙串、不联网、不运行 agy。
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yybar-google-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -o "$TEST_DIR/regression" Tests/GoogleQuotaRegression.swift \
  Core/Quota/GoogleQuotaClient.swift Core/Quota/GrokBotQuotaClient.swift Core/Quota/GeminiAppQuotaClient.swift \
  Core/Quota/GrokQuotaClient.swift Core/Quota/QuotaModels.swift Core/Credentials/JWT.swift Core/Credentials/AccountTokenFiles.swift \
  Core/Usage/UsageModels.swift Core/Usage/Pricing.swift Core/Usage/GeminiAnswerLog.swift
"$TEST_DIR/regression" "$@"
