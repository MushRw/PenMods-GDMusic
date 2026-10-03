#!/bin/bash
# 在真机上跑歌单页探针：推 qmlscene 脚本 -> 加载设备上的 main.qml -> 断言 -> 检查零警告。
#
# ⚠️ 前提：设备上的插件必须已经是本次改动后的版本（先跑 tools/deploy.sh）。
#    探针加载的是 /userdisk/PenMods/plugins/gdmusic/qml/main.qml，也就是设备上的那份。
#
# 跑完必须 grep 警告并要求**零输出**：设备日志写 flash，
# 一条 "Unable to assign [undefined] to bool" 会按帧刷，比断言失败更危险。
set -euo pipefail

S="${ADB_SERIAL:-}"
[ -n "$S" ] || { echo "需要设备序列号：先跑 adb devices 查到，再 export ADB_SERIAL=<序列号>"; exit 1; }
DIR=/userdisk/PenMods/plugins/gdmusic/qml
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
PROBE="$ROOT/probe/playlist-ui-device.qml"
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

echo "--- 推送探针 ---"
adb -s "$S" push "$PROBE" /tmp/ < /dev/null

echo "--- 真机执行（qmlscene, offscreen, 90s 上限）---"
OUT=$(adb -s "$S" shell "cd $DIR && HOME=/tmp QT_QPA_PLATFORM=offscreen timeout 90 /usr/bin/qmlscene /tmp/playlist-ui-device.qml 2>&1" < /dev/null | tr -d '\r')
echo "$OUT"

echo ""
echo "--- 警告检查（必须为空）---"
WARN=$(printf '%s\n' "$OUT" | grep -E "Error:|Unable to assign|TypeError|ReferenceError|is not a function|Cannot read propert|QML (Debug|Warning)|Assertion failed" || true)
if [ -n "$WARN" ]; then
    echo "❌ 出现警告/异常："
    printf '%s\n' "$WARN"
    exit 1
fi
echo "ok 零警告 ✅"

echo ""
echo "--- 结果 ---"
DONE=$(printf '%s\n' "$OUT" | grep "CHECK DONE" || true)
if [ -z "$DONE" ]; then
    echo "❌ 没跑到 CHECK DONE（崩了或被 timeout 掐了）"
    exit 1
fi
echo "$DONE"
if printf '%s\n' "$DONE" | grep -q "bad=0"; then
    echo "✅ 真机探针全过"
else
    echo "❌ 有失败项，见上面 BAD 行"
    exit 1
fi
