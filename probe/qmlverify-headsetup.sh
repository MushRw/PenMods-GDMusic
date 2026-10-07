#!/bin/bash
# 差分对照搭建（**在主机上跑**，通过 adb 操作设备）：
# 把设备上的插件整份复制到工作目录的 headqml/，再**用本地 HEAD 的 MediaBridge.qml 覆盖它**。
# 用途：同一份严格夹具分别对「设备部署版」和「HEAD 版」跑，证明夹具能区分两版（非恒真/恒假）。
#
# 用法：bash qmlverify-headsetup.sh <序列号> [工作目录] [HEAD MediaBridge 的本地路径]
# ⚠️ 只读源目录 /userdisk/PenMods/plugins/gdmusic/，所有写入都在工作目录下。
set -euo pipefail

S="${1:?需要设备序列号}"
WORK="${2:-/tmp/qmlverify}"
HEADMB="${3:-}"
SRC=/userdisk/PenMods/plugins/gdmusic/qml
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

sh_dev() { adb -s "$S" shell "$1" 2>&1 | tr -d '\r'; }

sh_dev "rm -rf $WORK/headqml; mkdir -p $WORK/headqml; cp -r $SRC/. $WORK/headqml/"
echo "  已复制设备插件到 $WORK/headqml（仅作对照，未改设备上的插件）"

if [ -n "$HEADMB" ] && [ -f "$HEADMB" ]; then
  # HEADMB 可能是 unix 路径（Git Bash），转成 Windows 路径给 adb
  HEADMB_W="$(cygpath -w "$HEADMB" 2>/dev/null || echo "$HEADMB")"
  adb -s "$S" push "$HEADMB_W" "$WORK/headqml/MediaBridge.qml" >/dev/null
  echo "  已用本地 HEAD 版覆盖 headqml/MediaBridge.qml"
  echo "  设备端 md5 复核："
  sh_dev "md5sum $WORK/headqml/MediaBridge.qml $SRC/MediaBridge.qml" | sed 's/^/    /'
else
  echo "  ⚠️ 未提供 HEAD MediaBridge 路径 ⇒ headqml 仍是设备部署版，差分无意义"
  exit 2
fi
