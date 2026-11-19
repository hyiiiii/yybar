#!/bin/bash
# 构建 Release 版 yybar.app 并签名，最后一行输出 .app 的路径(其余输出都走 stderr)。
# build_and_install.sh(装到本机)和 make_dmg.sh(打发布用的 DMG)共用。
# 用本机钥匙串里的「yybar Local Code Signing」自签证书签名：每次构建的签名身份相同，
# 钥匙串里点过「始终允许」的条目不会因为重新构建而再次询问。证书由 scripts/make_signing_cert.sh 创建。
# 加 --universal 编 arm64 + x86_64 通用二进制(Intel Mac 也能跑),否则只编本机架构。
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="${DERIVED_DATA:-/private/tmp/yybar-release}"
ARCH_FLAGS=()
if [ "${1:-}" = "--universal" ]; then
  ARCH_FLAGS=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
fi
xcodebuild -project yybar.xcodeproj -scheme yybar -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} build | tail -3 >&2
APP="$DERIVED/Build/Products/Release/yybar.app"

IDENTITY=$(security find-identity -p codesigning | awk '/"yybar Local Code Signing"/ {print $2; exit}')
if [ -z "$IDENTITY" ]; then
  echo "没找到 yybar Local Code Signing 证书，改用 ad-hoc 签名(之后每次构建钥匙串都会重新询问)。先运行 scripts/make_signing_cert.sh 可解决。" >&2
  IDENTITY="-"
fi
codesign --force --deep --sign "$IDENTITY" --entitlements yybar.entitlements "$APP" >&2
echo "$APP"
