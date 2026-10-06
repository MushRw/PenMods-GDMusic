#!/bin/sh
# ============================================================
# ⚠️ NOT-A-TEST —— 这是**诊断打印件**，不是断言件。
#
# 本文件只 echo 观察结果，没有 pass/bad 判定，也**不会**因为失败而返回非 0。
# ⇒ 它的"绿"不构成任何回归保护，别把它当门禁看。
#
# 2026-10-05 标注：探针目录里"真断言件"与"诊断打印件"混在一起，
# 新人看到满屏 ✅ 就以为验过了 —— 而这一类压根没有 ✅。
# 真断言件长这样：有 pass/bad 计数、结尾 `exit 1`、输出被别的 .sh grep
# （例：addpick-device.sh:47 `grep -q "bad=0"`、login-device.sh:39、
#       sidecar-e2e.sh 的 ok/bade 体系）。
# 判定脚本想变断言件：加 bad 计数 + 结尾 `exit $bad`，别只改文案。
# 详细清单见 audit-report/gdmusic-probe-ref.md 第一节 C。
# ============================================================
# 正确判据：直接连续采样 time-pos，看它是否随时间增长
set -u
HOST=music-api.gdstudio.xyz
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
IPS="104.18.0.1 104.17.0.1 104.19.0.1"

api() {
    for ip in $IPS; do
        r=$(LC_ALL=C curl -s --max-time 10 -A 'Mozilla/5.0' --resolve "$HOST:443:$ip" "https://$HOST/api.php?$1" 2>/dev/null)
        case "$r" in "["*|"{"*) printf '%s' "$r"; return 0;; esac
    done
    return 1
}

pkill -f '[i]nput-ipc-server=' 2>/dev/null
pkill -f '[u]serdisk/mpv' 2>/dev/null
sleep 1

U=""
for id in 2652820720 2668397359 210049 509781655; do
    u=$(api "types=url&source=netease&id=$id&br=320" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    [ -n "$u" ] && { U="$u"; break; }
done
[ -z "$U" ] && { echo "无可用 url"; exit 1; }

sample() {
    label="$1"; tag="$2"; shift 2
    SOCK="/tmp/gd_$tag.sock"
    rm -f "$SOCK"
    echo "== $label =="
    nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --volume=80 \
          --input-ipc-server="$SOCK" "$@" "$U" >/tmp/s_$tag.log 2>&1 &
    i=0; while [ $i -lt 60 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.25; done
    for n in $(seq 1 10); do
        sleep 2
        printf "   t+%2ds  %s\n" $((n*2)) "$(LC_ALL=C "$IPC" "$SOCK" status)"
    done
    LC_ALL=C "$IPC" "$SOCK" cmd quit >/dev/null 2>&1
    sleep 1
    pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null
    rm -f "$SOCK"
}

sample "默认配置（复现原始用法）" A
sample "--no-config"              B --no-config

echo "== 判读：pos 若不随时间增长即为真卡死 =="
