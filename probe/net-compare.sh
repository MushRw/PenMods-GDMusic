#!/bin/sh
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
