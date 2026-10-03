#!/bin/sh
# 用「优选 Cloudflare IP + 正确 SNI/Host」去连 gdstudio，验证是否绕开坏边缘
set -u
HOST="music-api.gdstudio.xyz"
PATHQ="/api.php?types=search&source=netease&name=test&count=1"
UA="Mozilla/5.0"

# 已知好 IP 在前，已知坏 IP 在后作对照
IPS="104.16.124.96 104.16.123.96 172.64.80.1 104.18.32.47 104.17.0.1 162.159.140.1 104.21.33.148 172.67.146.132"

for ip in $IPS; do
    r=$(curl -s -o /tmp/cf.json -w "%{http_code}:%{time_connect}:%{time_total}" --max-time 10 \
         --resolve "$HOST:443:$ip" -A "$UA" "https://$HOST$PATHQ" 2>/dev/null)
    sz=$(wc -c < /tmp/cf.json 2>/dev/null || echo 0)
    body=$(head -c 60 /tmp/cf.json 2>/dev/null | tr -d '\n')
    printf "  %-16s -> %s size=%s  %s\n" "$ip" "$r" "$sz" "$body"
done
