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
# 干净诊断：mpv 为何不进入播放
set -u
HOST=music-api.gdstudio.xyz
SOCK=/tmp/gdmusic.sock
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl

api() {
    for ip in 104.18.0.1 104.17.0.1; do
        r=$(curl -s --max-time 4 -A 'Mozilla/5.0' --resolve "$HOST:443:$ip" "https://$HOST/api.php?$1")
        case "$r" in [*|{*) printf '%s' "$r"; return 0;; esac
    done
    return 1
}

echo "== 现存 mpv 进程 =="
ps w 2>/dev/null | grep '[m]pv' || echo "  无"

echo "== 清理残留 =="
pkill -f '[i]nput-ipc-server=' 2>/dev/null
pkill -f '[u]serdisk/mpv' 2>/dev/null
sleep 2
ps w 2>/dev/null | grep '[m]pv' || echo "  已清空"

U=$(api "types=url&source=netease&id=5257138&br=320" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
echo "== url: $(echo "$U" | cut -c1-70) =="

echo "== 启动 mpv（全量日志，等 12 秒） =="
rm -f /tmp/m.log "$SOCK"
nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes \
      --msg-level=all=info --volume=80 --input-ipc-server="$SOCK" "$U" >/tmp/m.log 2>&1 &
sleep 12

echo "--- 日志（已滤掉字体噪音） ---"
grep -vE 'fontconfig|fontselect|Failed to load font' /tmp/m.log | tail -25

echo "--- 进程 ---"
ps w 2>/dev/null | grep '[m]pv' || echo "  mpv 已不在运行"

echo "--- 属性 ---"
if [ -S "$SOCK" ]; then
    for p in idle-active pause time-pos duration; do
        printf "  %-12s " "$p"
        LC_ALL=C "$IPC" "$SOCK" cmd get_property "$p"
    done
else
    echo "  socket 不存在"
fi

echo "== 清理 =="
LC_ALL=C "$IPC" "$SOCK" cmd quit >/dev/null 2>&1
sleep 1
pkill -f '[i]nput-ipc-server=' 2>/dev/null
pkill -f '[u]serdisk/mpv' 2>/dev/null
rm -f "$SOCK"
echo "== 诊断结束 =="
