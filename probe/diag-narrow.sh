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
# 收敛定位：默认配置下逐个关掉可疑项，看哪个能让播放恢复正常
set -u
HOST=music-api.gdstudio.xyz
IPS="104.18.0.1 104.17.0.1 104.19.0.1"

api() {
    for ip in $IPS; do
        r=$(LC_ALL=C curl -s --max-time 10 -A 'Mozilla/5.0' --resolve "$HOST:443:$ip" "https://$HOST/api.php?$1" 2>/dev/null)
        case "$r" in "["*|"{"*) printf '%s' "$r"; return 0;; esac
    done
    return 1
}

pkill -f '[u]serdisk/mpv' 2>/dev/null
sleep 1

U=""
for id in 2652820720 2668397359 210049 509781655; do
    u=$(api "types=url&source=netease&id=$id&br=320" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    [ -n "$u" ] && { U="$u"; break; }
done
[ -z "$U" ] && { echo "无可用 url"; exit 1; }
echo "url 就绪"

try() {
    label="$1"; shift
    T0=$(date +%s)
    timeout 40 /userdisk/mpv/mpv --really-quiet --no-video --force-window=no "$@" --length=10 "$U" >/tmp/len.log 2>&1
    rc=$?
    T1=$(date +%s)
    case $rc in
        0)  printf "  %-42s ✅ 正常（%ss）\n" "$label" "$((T1-T0))";;
        124) printf "  %-42s ❌ 卡死（被 timeout 杀）\n" "$label";;
        *)  printf "  %-42s ⚠️ 退出码 %s（%ss）\n" "$label" "$rc" "$((T1-T0))";;
    esac
}

echo "== 收敛测试（全部保留默认 config-dir，只覆盖单项） =="
try "基准：默认配置"
try "--hwdec=no"            --hwdec=no
try "--load-scripts=no"     --load-scripts=no
try "--cache-pause=no"      --cache-pause=no
try "--vo=null"             --vo=null
try "--keep-open=no"        --keep-open=no
echo "== 结束 =="
