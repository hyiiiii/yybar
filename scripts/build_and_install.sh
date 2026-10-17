#!/bin/bash
# 构建 Release 并安装到 /Applications/yybar.app(旧版本移到废纸篓，数据目录不受影响)。
# 用本机钥匙串里的「yybar Local Code Signing」自签证书签名：每次构建的签名身份相同，
# 钥匙串里点过「始终允许」的条目不会因为重新构建而再次询问。证书由 scripts/make_signing_cert.sh 创建。
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="${DERIVED_DATA:-/private/tmp/yybar-release}"
xcodebuild -project yybar.xcodeproj -scheme yybar -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build | tail -3
APP="$DERIVED/Build/Products/Release/yybar.app"

IDENTITY=$(security find-identity -p codesigning | awk '/"yybar Local Code Signing"/ {print $2; exit}')
if [ -z "$IDENTITY" ]; then
  echo "没找到 yybar Local Code Signing 证书，改用 ad-hoc 签名(之后每次构建钥匙串都会重新询问)。先运行 scripts/make_signing_cert.sh 可解决。"
  IDENTITY="-"
fi
codesign --force --deep --sign "$IDENTITY" --entitlements yybar.entitlements "$APP"

pkill -x yybar || true
sleep 1
rm -rf /Applications/yybar.app.new
ditto "$APP" /Applications/yybar.app.new
# 旧版本移到废纸篓(不直接删除),需要时可以从废纸篓放回。
if [ -e /Applications/yybar.app ]; then
  mv /Applications/yybar.app "$HOME/.Trash/yybar $(date +%Y%m%d-%H%M%S).app"
fi
mv /Applications/yybar.app.new /Applications/yybar.app
rm -rf "$APP"
open /Applications/yybar.app
echo "已安装 /Applications/yybar.app"
