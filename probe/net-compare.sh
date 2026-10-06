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
# 对比：普通站点 vs Cloudflare 站点的连通性
set -u
UA="Mozilla/5.0"
W="code=%{http_code} conn=%{time_connect} tls=%{time_appconnect} ttf=%{time_starttransfer} total=%{time_total}\n"

probe() {
    echo "--- $1"
    curl -s -o /dev/null -w "    $W" --max-time 15 -A "$UA" "$2" 2>&1
}

echo "###### 基线：普通站点 ######"
probe "baidu.com        (国内CDN)" "https://www.baidu.com/"
probe "qq.com           (国内CDN)" "https://www.qq.com/"
probe "music.126.net    (网易云CDN)" "https://m801.music.126.net/"

echo "###### Cloudflare 阵营 ######"
probe "gdstudio 默认" "https://music-api.gdstudio.xyz/api.php?types=search&source=netease&name=test&count=1"
probe "gdstudio -4" "https://music-api.gdstudio.xyz/api.php?types=search&source=netease&name=test&count=1"
probe "cloudflare.com" "https://www.cloudflare.com/"
probe "workers.dev" "https://workers.cloudflare.com/"

echo "###### 解析对比 ######"
for h in music-api.gdstudio.xyz www.cloudflare.com; do
    echo "  $h -> $(busybox nslookup $h 2>/dev/null | sed -n 's/.*Address [0-9]*: *\([0-9.]*\)$/\1/p' | tr '\n' ' ')"
done
