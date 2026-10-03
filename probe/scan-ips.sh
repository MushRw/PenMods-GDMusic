#!/bin/sh
# 巡检候选 Cloudflare IP，找出当前可用的
set -u
HOST=music-api.gdstudio.xyz
Q="/api.php?types=search&source=netease&name=test&count=1"
UA="Mozilla/5.0"

IPS="104.18.32.47 104.17.0.1 162.159.140.1 104.16.0.1 104.18.0.1 104.19.0.1 104.20.0.1 104.21.0.1 104.22.0.1 104.23.0.1 104.24.0.1 104.25.0.1 104.26.0.1 104.27.0.1 172.64.0.1 172.65.0.1 172.66.0.1 172.67.0.1 172.68.0.1 172.69.0.1 172.70.0.1 172.71.0.1 188.114.96.1 190.93.240.1 198.41.192.1"

good=""
for ip in $IPS; do
    r=$(curl -s -o /tmp/ip.json -w "%{http_code}:%{time_total}" --max-time 5 \
         --resolve "$HOST:443:$ip" -A "$UA" "https://$HOST$Q" 2>/dev/null)
    case "$r" in
        200:*)
            echo "  OK    $ip  $r"
            good="$good $ip"
            ;;
        *)
            echo "  --    $ip  $r"
            ;;
    esac
done
echo "当前可用:${good:- 无}"
