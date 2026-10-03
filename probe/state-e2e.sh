#!/bin/sh
# now.json 的 pause / status / idle 三字段真值性验证
#
# 背景（真机踩出来的）：mpv 的 flag 属性用 mp.get_property() 取到的是**字符串** "yes"/"no"，
# 拿它 == true 永远为假 ⇒ write_now 里 pause 恒 false、status 恒 "playing"、idle 恒 false。
#
# 验证方式同样是「隔离实例」：把 lua 里的 /tmp/gdmusic 换成 /tmp/gdst2，
# 起一个独立 mpv，用 IPC 改 pause 再发 gd-status（gd-status 无条件触发一次 write_now），
# 然后核对 now.json 是否如实反映。
#
# ⚠️ 不能用 & 丢后台后立刻返回：adb shell 派生的后台进程会话结束即被清理，
#    那样读到的会是"进程没了"的假象（踩过两次）。

T=/tmp/gdst2
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
SRC=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua
MPV=/userdisk/mpv/mpv

pass=0; fail=0
ck() {
    if [ "$2" = "1" ]; then echo "  PASS  $1"; pass=$((pass+1))
    else echo "  FAIL  $1"; fail=$((fail+1)); fi
}

rm -rf "$T"; mkdir -p "$T"

# 定点替换本次要验的那条 helper：实验组 native（布尔），对照组 string（永远比不出 true）
sed 's|/tmp/gdmusic|/tmp/gdst2|g; s|gdmusic\.lock|gdst2.lock|g' "$SRC" > "$T/fixed.lua"
sed 's|mp.get_property_native(name) == true|mp.get_property(name) == true|' "$T/fixed.lua" > "$T/old.lua"
cmp -s "$T/fixed.lua" "$T/old.lua" && { echo "  FAIL  两个变体相同，无法 A/B"; exit 1; }
echo "  PASS  A/B 变体已生成且确有差异"

field() { # field <now.json文本> <字段名>
    echo "$1" | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p"
}

run() { # run <变体名> -> 输出 now.json
    v="$1"; sock="$T/$v.sock"
    rm -f "$sock" "$T/now.json"
    nohup "$MPV" --no-video --force-window=no --idle=yes --keep-open=no \
          --input-ipc-server="$sock" --script="$T/$v.lua" > "$T/mpv_$v.log" 2>&1 &
    sleep 5
    r=""
    for expect in true false; do
        LC_ALL=C "$IPC" "$sock" cmd set_property pause "$expect" >/dev/null 2>&1
        sleep 1
        LC_ALL=C "$IPC" "$sock" cmd script-message gd-status >/dev/null 2>&1
        sleep 1
        r="$r$(cat "$T/now.json" 2>/dev/null)||"
    done
    pkill -f "[i]nput-ipc-server=$sock" 2>/dev/null
    sleep 1; rm -f "$sock"
    echo "$r"
}

echo "=== 对照：get_property（字符串）版 ==="
OLD=$(run old)
echo "=== 实验：get_property_native（布尔）版 ==="
NEW=$(run fixed)

O_PAUSED=$(echo "$OLD" | awk -F'\\|\\|' '{print $1}')
N_PAUSED=$(echo "$NEW" | awk -F'\\|\\|' '{print $1}')
N_PLAY=$(echo "$NEW"   | awk -F'\\|\\|' '{print $2}')

echo
echo "=== 断言 ==="
echo "--- 修复前（应复现：暂停了还说在播）---"
[ "$(field "$O_PAUSED" pause)" = "false" ] && ck "对照组 pause 恒 false（bug 复现）" 1 || ck "对照组 pause 恒 false（bug 复现）" 0
echo "--- 修复后：暂停态 ---"
[ "$(field "$N_PAUSED" pause)" = "true" ] && ck "暂停时 pause=true" 1 || ck "暂停时 pause=true（实为 $(field "$N_PAUSED" pause)）" 0
[ "$(field "$N_PAUSED" status)" = '"paused"' ] && ck "暂停时 status=paused" 1 || ck "暂停时 status=paused（实为 $(field "$N_PAUSED" status)）" 0
echo "--- 修复后：播放态 ---"
[ "$(field "$N_PLAY" pause)" = "false" ] && ck "播放时 pause=false" 1 || ck "播放时 pause=false（实为 $(field "$N_PLAY" pause)）" 0
[ "$(field "$N_PLAY" status)" = '"playing"' ] && ck "播放时 status=playing" 1 || ck "播放时 status=playing（实为 $(field "$N_PLAY" status)）" 0
echo "--- idle（无文件时应为 true）---"
[ "$(field "$N_PAUSED" idle)" = "true" ] && ck "idle-active 如实为 true" 1 || ck "idle-active 如实为 true（实为 $(field "$N_PAUSED" idle)）" 0
[ "$(field "$O_PAUSED" idle)" = "false" ] && ck "对照组 idle 恒 false（bug 复现）" 1 || ck "对照组 idle 恒 false（bug 复现）" 0

pkill -f "[i]nput-ipc-server=$T" 2>/dev/null
rm -f /tmp/audio_wakelocks/gdst2.lock; rm -rf "$T"

echo
echo "==== $pass PASS / $fail FAIL ===="
[ "$fail" = 0 ]
