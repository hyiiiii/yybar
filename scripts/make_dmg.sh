#!/bin/bash
# 打发布用的 macOS 安装包 dist/yybar-<版本>.dmg:arm64 + x86_64 通用二进制，用本机自签证书签名，未经 Apple 公证。
# 用户打开 DMG 把 yybar 拖进「应用程序」即可；第一次打开会被系统拦下，要在「系统设置 › 隐私与安全性」里点「仍要打开」。
set -euo pipefail
cd "$(dirname "$0")/.."

APP=$(scripts/build_release.sh --universal | tail -1)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
DMG="dist/yybar-$VERSION.dmg"

STAGE=$(mktemp -d /private/tmp/yybar-dmg.XXXXXX)
ditto "$APP" "$STAGE/yybar.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "yybar $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

lipo -info "$APP/Contents/MacOS/yybar"
shasum -a 256 "$DMG"
echo "已生成 $DMG"
