#!/bin/bash
# 构建 Release 并安装到 /Applications/yybar.app(旧版本移到废纸篓，数据目录不受影响)。
# 构建和签名见 scripts/build_release.sh。
set -euo pipefail
cd "$(dirname "$0")/.."

APP=$(scripts/build_release.sh | tail -1)

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
