#!/bin/bash
# 在真机上跑 sidecar 探针：预置真实封面 -> 推 qmlscene -> 加载设备上的 main.qml -> 断言 -> 零警告。
#
# ⚠️ 前提：设备上的插件必须已经是本次改动后的版本（先跑 tools/deploy.sh）。
#    探针加载的是 /userdisk/PenMods/plugins/gdmusic/qml/main.qml，也就是设备上的那份。
#
# ⛔ 为什么要先"预置封面"：
#   sidecar-device.qml 的 F 段用同步 Image（asynchronous:false）读本地 jpg，
#   而同步加载发生在**组件创建时** —— 也就是 qmlscene 刚起来的那一瞬。
#   那时文件要是不存在，status 直接变 Error 且不会重试，探针永远红。
#   所以封面必须在本脚本里、qmlscene 之前用**真源码生成的 buildCoverCmd** 下好。
#   （顺带这条路径本身就是"命令能被 /bin/sh 跑通"的又一次真实验证）
#
# 跑完必须 grep 警告并要求**零输出**：设备日志写 flash，
# 一条 "Unable to assign [undefined] to bool" 会按帧刷，比断言失败更危险。
set -euo pipefail

S="${ADB_SERIAL:-}"
[ -n "$S" ] || { echo "需要设备序列号：先跑 adb devices 查到，再 export ADB_SERIAL=<序列号>"; exit 1; }
DIR=/userdisk/PenMods/plugins/gdmusic/qml
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
PROBE="$ROOT/probe/sidecar-device.qml"
NODE="${NODE:-}"
QML="$ROOT/plugin/qml/main.qml"

# 探针里写死的两个路径，改了一边记得改另一边（下面有一致性断言兜着）
BASE=/userdisk/Music/GDMusic/屋顶-周杰伦
IMG="$BASE.jpg"
URL="https://p2.music.126.net/81BsxxhomJ4aJZYvEbyPkw==/109951165671182684.jpg?param=500y500"

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

[ -x "$NODE" ] || NODE=$(command -v node)

pass=0; bad=0
ok()   { pass=$((pass+1)); echo "  ✅ $1"; }
bade() { bad=$((bad+1));  echo "  ❌ $1"; }

d() { adb -s "$S" shell "$1" </dev/null; }

echo "=== 1. 预置真实封面（用真源码生成的 buildCoverCmd）==="
EVALJSON="$ROOT/.tmp/sidecar-dev-eval.json"
mkdir -p "$ROOT/.tmp"
"$NODE" "$ROOT/probe/sidecar-eval.js" "$QML" "$BASE.mp3" "$URL" > "$EVALJSON"

# 探针里 REALIMG 写的是 BASE + ".jpg"，这里断言求值器推出来的也是同一个路径
# —— 不一致的话 F 段会去读另一个文件，然后报"Image 没 Ready"，根因却在探针本身
GOTIMG=$("$NODE" -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(o.img)' "$EVALJSON")
if [ "$GOTIMG" = "$IMG" ]; then
    ok "求值器与探针约定同一个封面路径：$GOTIMG"
else
    bade "路径不一致！求值器=$GOTIMG 探针=$IMG —— 改 probe/sidecar-device.qml 的 BASE"
    exit 1
fi

d "rm -f '$IMG'; true" >/dev/null
COVER_CMD=$("$NODE" -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(o.cover)' "$EVALJSON")
d "$COVER_CMD" >/dev/null 2>&1 || true
sleep 3
ISIZE=$(d "stat -c%s '$IMG' 2>/dev/null || echo 0" | tr -d ' \r')
if [ -n "$ISIZE" ] && [ "$ISIZE" -gt 1000 ]; then
    ok "封面已就位（$ISIZE 字节）"
else
    bade "封面没下下来（size='$ISIZE'）—— 探针的 F 段一定红，先解决这个"
    exit 1
fi
rm -f "$EVALJSON"

echo ""
echo "=== 2. 推送并执行探针 ==="
adb -s "$S" push "$PROBE" /tmp/ < /dev/null >/dev/null
OUT=$(adb -s "$S" shell "cd $DIR && HOME=/tmp QT_QPA_PLATFORM=offscreen timeout 90 /usr/bin/qmlscene /tmp/sidecar-device.qml 2>&1" < /dev/null | tr -d '\r')
echo "$OUT"

echo ""
echo "=== 3. 清理预置的封面（别留在用户歌库里）==="
d "rm -f '$IMG'; true" >/dev/null
ok "已清理"

echo ""
echo "--- 警告检查（必须为空）---"
WARN=$(printf '%s\n' "$OUT" | grep -E "Error:|Unable to assign|TypeError|ReferenceError|is not a function|Cannot read propert|QML (Debug|Warning)|Assertion failed" || true)
if [ -n "$WARN" ]; then
    echo "❌ 出现警告/异常："
    printf '%s\n' "$WARN"
    exit 1
fi
echo "  ✅ 零警告"

echo ""
echo "--- 结果 ---"
DONE=$(printf '%s\n' "$OUT" | grep "CHECK DONE" || true)
if [ -z "$DONE" ]; then
    echo "❌ 没跑到 CHECK DONE（崩了或被 timeout 掐了）"
    exit 1
fi
if printf '%s\n' "$OUT" | grep -q "bad=0"; then
    echo "$DONE"
    echo "✅ 真机 sidecar 探针全过"
else
    echo "$DONE"
    echo "❌ 有失败项，见上面 ❌ 行"
    exit 1
fi
